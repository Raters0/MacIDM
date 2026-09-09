import Foundation
import IDMEngine

/// Maps engine/bridge error codes to user-facing copy with a suggested next
/// action, so the UI never shows raw technical messages. Every string goes
/// through `String(localized:)` so the English catalog can translate the
/// whole mapping without touching call sites.
enum ErrorPresentation {
    struct Friendly {
        let title: String
        let message: String
    }

    static func describe(_ error: Error) -> Friendly {
        if let engineError = error as? IDMError {
            return describe(engineError)
        }
        return Friendly(
            title: String(localized: "下载错误"),
            message: error.localizedDescription
        )
    }

    static func describe(_ error: IDMError) -> Friendly {
        switch error {
        case .invalidURL:
            return Friendly(
                title: String(localized: "无效地址"),
                message: String(localized: "下载地址无法识别，请检查后重新粘贴。")
            )
        case .unsupportedScheme:
            return Friendly(
                title: String(localized: "不支持的协议"),
                message: String(localized: "仅支持 HTTP/HTTPS 链接。")
            )
        case .invalidParallelRequests:
            return Friendly(
                title: String(localized: "参数错误"),
                message: String(localized: "并行请求数需在 1–32 之间。")
            )
        case .invalidExpectedHash:
            return Friendly(
                title: String(localized: "校验值格式错误"),
                message: String(localized: "SHA-256 应为 64 位十六进制字符。")
            )
        case .pathNotWritable:
            return Friendly(
                title: String(localized: "无法写入"),
                message: String(localized: "目标目录没有写入权限，请在设置中更换保存位置。")
            )
        case .filenameConflict:
            return Friendly(
                title: String(localized: "文件名冲突"),
                message: String(
                    localized: "同名文件已存在。点击「改名重试」换一个文件名即可继续，无需重新下载。"
                )
            )
        case .invalidContentRange:
            return Friendly(
                title: String(localized: "服务器响应异常"),
                message: String(localized: "服务器返回了无效的分段信息，请尝试重新下载。")
            )
        case .rangeIgnored:
            return Friendly(
                title: String(localized: "服务器不支持分段"),
                message: String(
                    localized: "服务器忽略了分段请求，已无法按当前方式续传，请重新开始下载。"
                )
            )
        case .resourceChanged:
            return Friendly(
                title: String(localized: "资源已变化"),
                message: String(localized: "服务器上的文件已更新，与断点不匹配。请删除任务后重新下载。")
            )
        case .authenticationRequired:
            return Friendly(
                title: String(localized: "需要登录"),
                message: String(localized: "该资源需要登录或授权。建议从 Chrome 插件重新提交，以携带登录状态。")
            )
        case .httpStatus(let status):
            return Friendly(
                title: String(localized: "服务器错误"),
                message: httpSuggestion(for: status)
            )
        case .storageError(let detail):
            return Friendly(
                title: String(localized: "磁盘写入失败"),
                message: String(localized: "检查磁盘空间和目录权限后重试。（\(detail)）")
            )
        case .sidecarCorrupt:
            return Friendly(
                title: String(localized: "断点数据损坏"),
                message: String(
                    localized:
                        "续传校验信息已损坏。引擎已自动重试并尝试丢弃断点重新开始，仍未成功；点击「重试」可再次从头下载。"
                )
            )
        case .verificationFailed:
            return Friendly(
                title: String(localized: "校验失败"),
                message: String(localized: "SHA-256 与预期不一致，文件可能已损坏，建议重新下载。")
            )
        case .paused:
            return Friendly(
                title: String(localized: "已暂停"),
                message: String(localized: "任务已暂停。")
            )
        case .cancelled:
            return Friendly(
                title: String(localized: "已取消"),
                message: String(localized: "任务已取消。")
            )
        case .timedOut:
            return Friendly(
                title: String(localized: "请求超时"),
                message: String(localized: "网络连接或媒体缓冲等待超时，请检查网络后重试。")
            )
        case .responseTooShort, .responseTooLong:
            return Friendly(
                title: String(localized: "连接中断"),
                message: String(localized: "网络传输被中断。使用「继续」可从断点恢复。")
            )
        case .resourceTooLarge(let maximumBytes):
            return Friendly(
                title: String(localized: "资源过大"),
                message: String(
                    localized:
                        "单个缓冲资源超过安全上限 \(maximumBytes / (1_024 * 1_024)) MB，已中止以保护系统。"
                )
            )
        }
    }

    /// Friendly copy for app-level error codes stored on tasks.
    static func describe(code: String, fallbackMessage: String?) -> Friendly {
        switch code {
        case "NEEDS_REFETCH":
            return Friendly(
                title: String(localized: "需要重新提交"),
                message: String(
                    localized: "带参数的下载地址不会被持久化保存。请从原始页面或 Chrome 插件重新提交该下载。"
                )
            )
        case "TAKEOVER_TIMEOUT":
            return Friendly(
                title: String(localized: "接管超时"),
                message: String(localized: "等待浏览器确认超时。请从 Chrome 重新提交下载。")
            )
        case "TAKEOVER_REJECTED":
            return Friendly(
                title: String(localized: "接管被拒绝"),
                message: fallbackMessage
                    ?? String(localized: "浏览器取消了本次接管，浏览器下载已保留。")
            )
        case "INTERRUPTED":
            return Friendly(
                title: String(localized: "已中断"),
                message: String(localized: "App 退出导致下载中断，点击「继续」即可恢复。")
            )
        case "CONTEXT_UNSUPPORTED":
            return Friendly(
                title: String(localized: "无法接管"),
                message: fallbackMessage
                    ?? String(
                        localized: "该下载需要登录鉴权上下文，当前版本无法安全传递。已在浏览器中继续下载。"
                    )
            )
        case "APP_REJECTED":
            return Friendly(
                title: String(localized: "接管被拒绝"),
                message: fallbackMessage
                    ?? String(localized: "MacIDM 拒绝了本次接管，浏览器下载已保留。")
            )
        case "SOURCE_UNSUPPORTED":
            return Friendly(
                title: String(localized: "暂不支持"),
                message: fallbackMessage
                    ?? String(localized: "该资源（blob/DRM/脚本生成）暂不支持下载。")
            )
        case "FFMPEG_UNAVAILABLE":
            return Friendly(
                title: String(localized: "需要 FFmpeg"),
                message: String(
                    localized:
                        "HLS/DASH 视频需要 ffmpeg 才能合并与转码。请安装 ffmpeg（如 brew install ffmpeg）后重启 MacIDM，MacIDM 会自动检测系统中的 ffmpeg。"
                )
            )
        case "NEEDS_AUTH":
            return Friendly(
                title: String(localized: "登录态已过期"),
                message: String(
                    localized: "浏览器授权的下载上下文已过期。请回到原网页，在 Chrome 中重新通过 MacIDM 插件提交该下载。"
                )
            )
        case "YTDLP_BOT_CHECK":
            return Friendly(title: String(localized: "YouTube 风控拦截"), message: fallbackMessage ?? "")
        case "YTDLP_N_CHALLENGE_FAILED":
            return Friendly(title: String(localized: "缺少 JavaScript 运行时"), message: fallbackMessage ?? "")
        case "YTDLP_GEO_BLOCKED":
            return Friendly(title: String(localized: "地区限制"), message: fallbackMessage ?? "")
        case "YTDLP_AGE_RESTRICTED":
            return Friendly(title: String(localized: "年龄限制"), message: fallbackMessage ?? "")
        case "YTDLP_PRIVATE_VIDEO":
            return Friendly(title: String(localized: "私密视频"), message: fallbackMessage ?? "")
        case "YTDLP_COPYRIGHT":
            return Friendly(title: String(localized: "版权限制"), message: fallbackMessage ?? "")
        case "YTDLP_VIDEO_UNAVAILABLE":
            return Friendly(title: String(localized: "视频不可用"), message: fallbackMessage ?? "")
        case "YTDLP_LIVE_ENDED":
            return Friendly(title: String(localized: "直播回放不可用"), message: fallbackMessage ?? "")
        case "YTDLP_NETWORK_ERROR":
            return Friendly(title: String(localized: "网络连接失败"), message: fallbackMessage ?? "")
        case "YTDLP_UNSUPPORTED_URL":
            return Friendly(title: String(localized: "链接不受支持"), message: fallbackMessage ?? "")
        case "YTDLP_STALLED":
            return Friendly(title: String(localized: "解析超时"), message: fallbackMessage ?? "")
        case "YTDLP_CLEANUP_FAILED":
            return Friendly(title: String(localized: "进程清理未完成"), message: fallbackMessage ?? "")
        case "YTDLP_PROCESS_FAILED":
            return Friendly(title: String(localized: "解析失败"), message: fallbackMessage ?? "")
        case "YTDLP_NO_MEDIA":
            return Friendly(title: String(localized: "未生成媒体文件"), message: fallbackMessage ?? "")
        case "YTDLP_FFMPEG_UNAVAILABLE":
            return Friendly(title: String(localized: "缺少 FFmpeg"), message: fallbackMessage ?? "")
        default:
            return Friendly(
                title: code,
                message: fallbackMessage ?? String(localized: "发生未知错误。")
            )
        }
    }

    private static func httpSuggestion(for status: Int) -> String {
        switch status {
        case 401, 403:
            String(
                localized:
                    "服务器拒绝访问（HTTP \(status)）。若资源需要登录，请在 Chrome 中先登录该站点再重新提交；若是视频/CDN 资源，确认已通过 Chrome 插件提交（MacIDM 会自动携带浏览器的 Referer 与登录态）。仍失败可能是该站点需要单独的下载工具。"
            )
        case 404:
            String(localized: "资源不存在（HTTP 404）。链接可能已失效。")
        case 416:
            String(localized: "请求的范围无效（HTTP 416）。断点可能已失效，请重新开始下载。")
        case 429:
            String(localized: "服务器限流（HTTP 429）。请稍后重试，或降低并行请求数。")
        case 500...599:
            String(localized: "服务器内部错误（HTTP \(status)）。请稍后重试。")
        default:
            String(localized: "服务器返回错误（HTTP \(status)）。请稍后重试。")
        }
    }
}
