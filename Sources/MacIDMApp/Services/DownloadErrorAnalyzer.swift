import Foundation
import IDMEngine

/// Structured diagnosis of a download failure. Produced by
/// `DownloadErrorAnalyzer` for every failed task so the UI can show a
/// precise category, probable cause, and an actionable next step instead
/// of a raw "download failed" message.
struct ErrorDiagnosis: Equatable, Sendable {
    enum Category: String, Sendable {
        /// URLSession-level connectivity: DNS, TCP, TLS, timeouts.
        case network
        /// The server refused the request without login/cookies.
        case authentication
        /// The resource itself is gone, changed, or the link is invalid.
        case resource
        /// The remote server is faulty (5xx).
        case server
        /// The remote server is throttling (429).
        case rateLimit
        /// Local disk or permission problems.
        case storage
        /// Stream manifest / segment / FFmpeg media pipeline problems.
        case media
        /// Site-imposed policy: geo blocks, age gates, copyright, privacy.
        case sitePolicy
        /// Missing or broken local tools (yt-dlp, FFmpeg, JS runtime).
        case toolchain
        /// Nothing matched — the diagnosis still carries copy hints.
        case unknown
    }

    let category: Category
    /// Short user-facing headline, such as a localized DNS-resolution error.
    let title: String
    /// Probable technical cause in plain language (URLs redacted).
    let cause: String
    /// Concrete next step the user can take.
    let recommendation: String
    /// True when providing a site session/cookie is likely the fix —
    /// `SessionStore` flows branch on this flag.
    let requiresSession: Bool
    /// True when retrying the same task could plausibly succeed.
    let retryable: Bool
}

/// Turns any download error into an `ErrorDiagnosis`. Coverage spans
/// engine HTTP failures, URLSession connectivity errors, FFmpeg problems,
/// and yt-dlp/YouTube-specific failures — one entry point so every
/// download type gets the same depth of analysis.
enum DownloadErrorAnalyzer {

    /// Contextual hints that sharpen classification. All fields optional;
    /// the analyzer degrades gracefully when a hint is missing.
    struct Context: Sendable {
        var domain: String?
        var sourceKind: DownloadSourceKind?
        var proxyEnabled: Bool
        /// yt-dlp process output when the failure came from the extractor.
        var processOutput: String?

        init(
            domain: String? = nil,
            sourceKind: DownloadSourceKind? = nil,
            proxyEnabled: Bool = false,
            processOutput: String? = nil
        ) {
            self.domain = domain
            self.sourceKind = sourceKind
            self.proxyEnabled = proxyEnabled
            self.processOutput = processOutput
        }
    }

    static func diagnose(error: Error, context: Context) -> ErrorDiagnosis {
        // Intentional user actions are not failures; callers normally skip
        // diagnosis for them, but stay defensive.
        if let engineError = error as? IDMError {
            switch engineError {
            case .paused:
                return ErrorDiagnosis(
                    category: .unknown,
                    title: String(localized: "已暂停"),
                    cause: String(localized: "用户主动操作"),
                    recommendation: String(localized: "无需处理。"),
                    requiresSession: false,
                    retryable: false
                )
            case .cancelled:
                return ErrorDiagnosis(
                    category: .unknown,
                    title: String(localized: "已取消"),
                    cause: String(localized: "用户主动操作"),
                    recommendation: String(localized: "无需处理。"),
                    requiresSession: false,
                    retryable: false
                )
            default:
                break
            }
            if let diagnosis = diagnose(engineError: engineError, context: context) {
                return diagnosis
            }
        }
        if let urlError = error as? URLError {
            return diagnose(urlError: urlError, context: context)
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return diagnose(nsErrorCode: nsError.code, context: context)
        }
        if let ffmpegError = error as? FFmpegError {
            return diagnose(ffmpegError: ffmpegError)
        }
        if let youtubeError = error as? YouTubeDownloadError {
            return diagnose(youtubeError: youtubeError, context: context)
        }
        return fallback(error: error, context: context)
    }

    // MARK: - Engine errors

    private static func diagnose(engineError: IDMError, context: Context) -> ErrorDiagnosis? {
        switch engineError {
        case .authenticationRequired:
            return sessionDiagnosis(
                title: String(localized: "需要登录"),
                cause: String(localized: "服务器要求登录后才能访问该资源。"),
                context: context
            )
        case .httpStatus(let status):
            return diagnose(httpStatus: status, context: context)
        case .resourceChanged:
            return ErrorDiagnosis(
                category: .resource,
                title: String(localized: "资源已变化"),
                cause: String(localized: "服务器上的文件在续传期间被替换，断点已失效。"),
                recommendation: String(localized: "删除当前任务并重新添加下载。"),
                requiresSession: false,
                retryable: false
            )
        case .sidecarCorrupt:
            return ErrorDiagnosis(
                category: .resource,
                title: String(localized: "断点数据损坏"),
                cause: String(localized: "本地续传校验文件无法解析；引擎已自动重试并尝试丢弃断点重新开始，仍未成功。"),
                recommendation: String(localized: "点击「重试」让任务从头下载；若仍失败，取消该任务后重新添加。"),
                requiresSession: false,
                retryable: true
            )
        case .rangeIgnored:
            return ErrorDiagnosis(
                category: .resource,
                title: String(localized: "服务器不支持分段"),
                cause: String(localized: "服务器忽略了 Range 请求，无法按当前方式续传。"),
                recommendation: String(localized: "重新开始下载；若反复出现可尝试降低并行请求数为 1。"),
                requiresSession: false,
                retryable: true
            )
        case .filenameConflict:
            return ErrorDiagnosis(
                category: .storage,
                title: String(localized: "文件名冲突"),
                cause: String(localized: "目标目录中已存在同名文件。"),
                recommendation: String(localized: "使用「改名重试」或手动移动/删除已有文件。"),
                requiresSession: false,
                retryable: true
            )
        case .pathNotWritable, .storageError:
            return ErrorDiagnosis(
                category: .storage,
                title: String(localized: "磁盘写入失败"),
                cause: String(localized: "目标目录无写入权限或磁盘空间不足。"),
                recommendation: String(localized: "检查磁盘剩余空间与目录权限，或在设置中更换保存位置。"),
                requiresSession: false,
                retryable: true
            )
        case .verificationFailed:
            return ErrorDiagnosis(
                category: .resource,
                title: String(localized: "校验失败"),
                cause: String(localized: "SHA-256 与预期不一致，文件可能损坏或被替换。"),
                recommendation: String(localized: "重新下载；若反复失败说明源文件本身有问题。"),
                requiresSession: false,
                retryable: true
            )
        case .invalidURL, .unsupportedScheme:
            return ErrorDiagnosis(
                category: .resource,
                title: String(localized: "地址无效"),
                cause: String(localized: "下载地址无法识别或协议不受支持。"),
                recommendation: String(localized: "检查链接是否完整，仅支持 HTTP/HTTPS 链接。"),
                requiresSession: false,
                retryable: false
            )
        default:
            return nil
        }
    }

    private static func diagnose(httpStatus status: Int, context: Context) -> ErrorDiagnosis {
        switch status {
        case 401, 403:
            // HLS/DASH segments failing 403 en masse usually means the
            // signed manifest expired — refetching the playlist fixes it.
            if context.sourceKind == .hls || context.sourceKind == .dash {
                return ErrorDiagnosis(
                    category: .media,
                    title: String(localized: "流媒体签名过期"),
                    cause: String(localized: "清单中的分段签名 URL 已过期（HTTP \(status)）。"),
                    recommendation: String(localized: "重新提交原始页面链接以获取新的播放清单。"),
                    requiresSession: false,
                    retryable: false
                )
            }
            // Site-specific copy for bilibili: its CDN rejects requests
            // without the right login/referer, and premium content needs
            // a paid account.
            if let domain = context.domain, domain.contains("bilibili.com") {
                return ErrorDiagnosis(
                    category: .sitePolicy,
                    title: String(localized: "Bilibili 访问被拒（HTTP \(status)）"),
                    cause: String(localized: "B 站拒绝了当前请求：可能是大会员专属内容、地区限制，或缺少登录态/页面 Referer。"),
                    recommendation: String(
                        localized: "在 Chrome 中登录 B 站后通过 MacIDM 插件重新提交（自动携带登录态与 Referer）；大会员内容需开通对应账号。"
                    ),
                    requiresSession: true,
                    retryable: true
                )
            }
            return sessionDiagnosis(
                title: String(localized: "服务器拒绝访问（HTTP \(status)）"),
                cause: String(localized: "服务器拒绝了未携带登录状态的请求。"),
                context: context
            )
        case 404, 410:
            return ErrorDiagnosis(
                category: .resource,
                title: String(localized: "资源不存在（HTTP \(status)）"),
                cause: String(localized: "链接指向的文件已被删除或移动。"),
                recommendation: String(localized: "回到来源页面确认链接是否仍然有效。"),
                requiresSession: false,
                retryable: false
            )
        case 416:
            return ErrorDiagnosis(
                category: .resource,
                title: String(localized: "断点已失效（HTTP 416）"),
                cause: String(localized: "请求的字节范围超出资源，续传点不再有效。"),
                recommendation: String(localized: "重新开始下载。"),
                requiresSession: false,
                retryable: false
            )
        case 429:
            return ErrorDiagnosis(
                category: .rateLimit,
                title: String(localized: "服务器限流（HTTP 429）"),
                cause: String(localized: "并发请求过多触发了站点限速。"),
                recommendation: String(localized: "点击「降低并行数重试」减少并发；或稍后手动重试。"),
                requiresSession: false,
                retryable: true
            )
        case 500...599:
            return ErrorDiagnosis(
                category: .server,
                title: String(localized: "服务器错误（HTTP \(status)）"),
                cause: String(localized: "站点服务端故障，与本地环境无关。"),
                recommendation: String(localized: "稍后重试；持续失败说明站点侧长时间故障。"),
                requiresSession: false,
                retryable: true
            )
        default:
            return ErrorDiagnosis(
                category: .server,
                title: String(localized: "服务器响应异常（HTTP \(status)）"),
                cause: String(localized: "服务器返回了非预期的状态码。"),
                recommendation: String(localized: "稍后重试，或检查链接是否正确。"),
                requiresSession: false,
                retryable: true
            )
        }
    }

    // MARK: - URLSession / network errors

    private static func diagnose(urlError: URLError, context: Context) -> ErrorDiagnosis {
        diagnose(nsErrorCode: urlError.errorCode, context: context)
    }

    private static func diagnose(nsErrorCode code: Int, context: Context) -> ErrorDiagnosis {
        let proxyHint =
            context.proxyEnabled
            ? String(localized: "当前已启用代理，请确认代理服务本身可用。")
            : String(localized: "若该站点在你的网络环境下需要代理，请先在设置中配置代理。")
        switch code {
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return ErrorDiagnosis(
                category: .network,
                title: String(localized: "DNS 解析失败"),
                cause: String(localized: "无法解析目标域名，可能是域名错误、DNS 服务异常或被污染。"),
                recommendation: String(localized: "检查链接拼写与系统 DNS 设置；\(proxyHint)"),
                requiresSession: false,
                retryable: true
            )
        case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost,
            NSURLErrorResourceUnavailable:
            return ErrorDiagnosis(
                category: .network,
                title: String(localized: "连接失败"),
                cause: String(localized: "无法建立或保持到服务器的连接。"),
                recommendation: String(localized: "检查网络后使用「继续」重试；\(proxyHint)"),
                requiresSession: false,
                retryable: true
            )
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
            NSURLErrorServerCertificateHasBadDate:
            return ErrorDiagnosis(
                category: .network,
                title: String(localized: "TLS 握手失败"),
                cause: String(localized: "加密连接建立失败，可能是证书问题或中间代理干扰。"),
                recommendation: String(localized: "稍后重试；若持续失败请检查系统时间、代理或防火墙设置。"),
                requiresSession: false,
                retryable: true
            )
        case NSURLErrorTimedOut:
            return ErrorDiagnosis(
                category: .network,
                title: String(localized: "连接超时"),
                cause: String(localized: "服务器在限定时间内没有响应。"),
                recommendation: String(localized: "检查网络连通性后重试；\(proxyHint)"),
                requiresSession: false,
                retryable: true
            )
        case NSURLErrorNotConnectedToInternet:
            return ErrorDiagnosis(
                category: .network,
                title: String(localized: "本机未联网"),
                cause: String(localized: "系统当前没有可用的网络连接。"),
                recommendation: String(localized: "连接网络后使用「继续」恢复下载。"),
                requiresSession: false,
                retryable: true
            )
        default:
            return ErrorDiagnosis(
                category: .network,
                title: String(localized: "网络错误"),
                cause: String(localized: "系统网络层报告错误（代码 \(code)）。"),
                recommendation: String(localized: "稍后重试；\(proxyHint)"),
                requiresSession: false,
                retryable: true
            )
        }
    }

    // MARK: - FFmpeg

    private static func diagnose(ffmpegError: FFmpegError) -> ErrorDiagnosis {
        switch ffmpegError {
        case .executableNotFound:
            return ErrorDiagnosis(
                category: .toolchain,
                title: String(localized: "缺少 FFmpeg"),
                cause: String(localized: "未找到可用的 ffmpeg 可执行文件。"),
                recommendation: String(localized: "安装 ffmpeg（如 brew install ffmpeg）后重启应用。"),
                requiresSession: false,
                retryable: true
            )
        case .versionMismatch, .hashMismatch, .invalidToolchain:
            return ErrorDiagnosis(
                category: .toolchain,
                title: String(localized: "FFmpeg 工具链异常"),
                cause: String(localized: "ffmpeg/ffprobe 版本或完整性校验未通过。"),
                recommendation: String(localized: "在设置中重新配置或更新 FFmpeg 工具链。"),
                requiresSession: false,
                retryable: true
            )
        case .inputMissing, .invalidOutput:
            return ErrorDiagnosis(
                category: .media,
                title: String(localized: "媒体处理失败"),
                cause: String(localized: "FFmpeg 输入缺失或输出无效。"),
                recommendation: String(localized: "重新下载该任务；若反复失败说明源媒体已损坏。"),
                requiresSession: false,
                retryable: true
            )
        default:
            return ErrorDiagnosis(
                category: .media,
                title: String(localized: "FFmpeg 错误"),
                cause: ffmpegError.localizedDescription,
                recommendation: String(localized: "稍后重试；持续失败请检查 FFmpeg 配置。"),
                requiresSession: false,
                retryable: true
            )
        }
    }

    // MARK: - YouTube / yt-dlp

    private static func diagnose(youtubeError: YouTubeDownloadError, context: Context) -> ErrorDiagnosis {
        switch youtubeError {
        case .toolUnavailable:
            return ErrorDiagnosis(
                category: .toolchain,
                title: String(localized: "缺少 yt-dlp"),
                cause: String(localized: "未找到可执行的 yt-dlp。"),
                recommendation: String(localized: "在设置 → yt-dlp 中安装，或执行 brew install yt-dlp。"),
                requiresSession: false,
                retryable: true
            )
        case .toolLaunchFailed:
            return ErrorDiagnosis(
                category: .toolchain,
                title: String(localized: "yt-dlp 无法启动"),
                cause: String(localized: "已找到 yt-dlp，但进程启动失败（文件损坏或系统限制）。"),
                recommendation: String(localized: "在设置 → yt-dlp 中重新下载安装。"),
                requiresSession: false,
                retryable: true
            )
        case .botCheckBlocked:
            return sessionDiagnosis(
                title: String(localized: "YouTube 风控拦截"),
                cause: String(localized: "YouTube 判定当前请求为机器人并要求登录验证。"),
                context: context
            )
        case .nChallengeFailed:
            return ErrorDiagnosis(
                category: .toolchain,
                title: String(localized: "缺少 JavaScript 运行时"),
                cause: String(localized: "yt-dlp 需要 Node.js 或 Deno 解密视频签名。"),
                recommendation: String(localized: "安装 Node.js（brew install node）或 Deno（brew install deno）后重试。"),
                requiresSession: false,
                retryable: true
            )
        case .geoBlocked:
            return ErrorDiagnosis(
                category: .sitePolicy,
                title: String(localized: "地区限制"),
                cause: String(localized: "视频在你的地区不可用。"),
                recommendation: String(localized: "可尝试配置代理后重试；否则该视频无法下载。"),
                requiresSession: false,
                retryable: false
            )
        case .ageRestricted:
            return sessionDiagnosis(
                title: String(localized: "年龄限制"),
                cause: String(localized: "该视频需要登录并通过年龄验证。"),
                context: context
            )
        case .privateVideo:
            return sessionDiagnosis(
                title: String(localized: "私密视频"),
                cause: String(localized: "视频仅对被授权账号可见。"),
                context: context
            )
        case .copyrightClaimed:
            return ErrorDiagnosis(
                category: .sitePolicy,
                title: String(localized: "版权限制"),
                cause: String(localized: "视频因版权主张被限制。"),
                recommendation: String(localized: "该视频无法通过下载工具获取。"),
                requiresSession: false,
                retryable: false
            )
        case .videoUnavailable:
            return ErrorDiagnosis(
                category: .resource,
                title: String(localized: "视频不可用"),
                cause: String(localized: "视频已被删除、下架或链接无效。"),
                recommendation: String(localized: "确认链接是否仍然有效。"),
                requiresSession: false,
                retryable: false
            )
        case .liveStreamEnded:
            return ErrorDiagnosis(
                category: .resource,
                title: String(localized: "直播回放不可用"),
                cause: String(localized: "直播回放尚未生成或已被移除。"),
                recommendation: String(localized: "等待主播生成回放后再试。"),
                requiresSession: false,
                retryable: false
            )
        case .liveStreamUnsupported:
            return ErrorDiagnosis(
                category: .resource,
                title: String(localized: "直播暂不支持"),
                cause: String(localized: "内容正在直播或即将开始，MacIDM 只接受已结束的点播/回放。"),
                recommendation: String(localized: "直播结束并生成回放后再提交下载。"),
                requiresSession: false,
                retryable: false
            )
        case .liveStatusUnknown:
            return ErrorDiagnosis(
                category: .toolchain,
                title: String(localized: "直播状态无法确认"),
                cause: String(
                    localized: "直播探测失败或结果不可解析；为避免误下载活动直播，任务已安全中止。"),
                recommendation: String(localized: "稍后重试；若反复出现，请检查网络或在设置中更新 yt-dlp。"),
                requiresSession: false,
                retryable: true
            )
        case .networkFailure:
            return ErrorDiagnosis(
                category: .network,
                title: String(localized: "网络连接失败"),
                cause: String(localized: "yt-dlp 无法连接 YouTube 服务器。"),
                recommendation: String(localized: "检查网络连通性；若访问 YouTube 需要代理，请在设置中配置代理后重试。"),
                requiresSession: false,
                retryable: true
            )
        case .extractorUnsupported:
            return ErrorDiagnosis(
                category: .resource,
                title: String(localized: "链接不受支持"),
                cause: String(localized: "yt-dlp 无法识别该链接。"),
                recommendation: String(localized: "确认链接指向有效的视频页面。"),
                requiresSession: false,
                retryable: false
            )
        case .stalled:
            return ErrorDiagnosis(
                category: .network,
                title: String(localized: "解析超时"),
                cause: String(localized: "多次重试后 yt-dlp 仍无任何输出，多为网络问题。"),
                recommendation: String(localized: "检查网络连通性后重试；若访问 YouTube 需要代理，请先配置代理。"),
                requiresSession: false,
                retryable: true
            )
        case .processCleanupFailed:
            // Process-group cleanup exceeding its budget is a diagnosable failure (§3):
            // never silent, never auto-retried.
            return ErrorDiagnosis(
                category: .toolchain,
                title: String(localized: "进程清理未完成"),
                cause: String(localized: "yt-dlp 进程组未能在预算内全部退出。"),
                recommendation: String(localized: "稍后重试；若反复出现可在活动监视器中检查残留 yt-dlp 进程。"),
                requiresSession: false,
                retryable: true
            )
        case .mediaNotProduced:
            return ErrorDiagnosis(
                category: .media,
                title: String(localized: "未生成媒体文件"),
                cause: String(localized: "yt-dlp 成功退出但没有产出文件。"),
                recommendation: String(localized: "重试；若反复失败可尝试更换分辨率选项。"),
                requiresSession: false,
                retryable: true
            )
        case .ffmpegUnavailable:
            return ErrorDiagnosis(
                category: .toolchain,
                title: String(localized: "缺少 FFmpeg"),
                cause: String(localized: "YouTube 下载需要 FFmpeg 完成校验与发布。"),
                recommendation: String(localized: "安装 ffmpeg（如 brew install ffmpeg）后重试。"),
                requiresSession: false,
                retryable: true
            )
        case .invalidRequest, .processFailed:
            // Last-resort: mine the process output once more for anything
            // the runner did not catch.
            if let output = context.processOutput,
                YouTubeDownloadRunner.classifyProcessError(output: output) != .processFailed
            {
                return diagnose(
                    youtubeError: YouTubeDownloadRunner.classifyProcessError(output: output),
                    context: context
                )
            }
            return ErrorDiagnosis(
                category: .unknown,
                title: String(localized: "解析失败"),
                cause: String(localized: "yt-dlp 进程失败且未匹配到已知错误模式。"),
                recommendation: String(localized: "重试；若持续失败可尝试更新 yt-dlp 或在任务详情中复制诊断信息反馈。"),
                requiresSession: false,
                retryable: true
            )
        }
    }

    // MARK: - Helpers

    /// Shared copy for authentication-class failures. Explains both session
    /// sources (Chrome extension capture / manual cookie paste) and adapts
    /// to per-site context.
    private static func sessionDiagnosis(title: String, cause: String, context: Context) -> ErrorDiagnosis {
        let site = context.domain.map { String(localized: "站点 \($0) ") } ?? String(localized: "该站点")
        let recommendation = [
            String(localized: "\(site)需要登录态。"),
            String(localized: "推荐：在 Chrome 中登录该站点后通过 MacIDM 插件重新提交下载（自动携带会话）；"),
            String(localized: "也可以手动粘贴 Cookie（任务失败弹窗或设置→站点会话中操作）。"),
        ].joined()
        return ErrorDiagnosis(
            category: .authentication,
            title: title,
            cause: cause,
            recommendation: recommendation,
            requiresSession: true,
            retryable: true
        )
    }

    private static func fallback(error: Error, context: Context) -> ErrorDiagnosis {
        ErrorDiagnosis(
            category: .unknown,
            title: String(localized: "下载错误"),
            cause: String(error.localizedDescription.prefix(200)),
            recommendation: String(localized: "稍后重试；若持续失败请在任务详情中复制诊断信息并反馈。"),
            requiresSession: false,
            retryable: true
        )
    }
}
