import Foundation
import IDMEngine
import XCTest

@testable import MacIDMApp

/// 任务详情面板用持久化的 `errorCode` 渲染错误卡片：未知 code 会退化成
/// 「标题=原始 code」，用户看到的是一串大写英文常量。凡是会被写进任务的
/// code 都必须在这里有一份本地化文案。
final class ErrorPresentationTests: XCTestCase {

    /// 反例：`DASHDownloadError.code` / `AppModelError.code` 刚接入时若忘了
    /// 补文案，面板标题会直接显示 `DASH_RESUME_CORRUPT` 这类内部常量。
    func testPersistedFailureCodesAlwaysRenderLocalizedCopy() {
        let codes = [
            DASHDownloadError.mergerUnavailable.code,
            DASHDownloadError.missingVideoRepresentation.code,
            DASHDownloadError.invalidResponse.code,
            DASHDownloadError.resumeCorrupt.code,
            DASHDownloadError.resumeIncompatible.code,
            AppModelError.ffmpegUnavailable.code,
            AppModelError.duplicateDestination.code,
        ]
        for code in codes {
            let friendly = ErrorPresentation.describe(code: code, fallbackMessage: nil)
            XCTAssertNotEqual(
                friendly.title, code,
                "code \(code) 缺少本地化标题，面板会直接显示内部常量"
            )
            XCTAssertFalse(
                friendly.title.isEmpty,
                "code \(code) 的标题不得为空"
            )
            XCTAssertFalse(
                friendly.message.isEmpty,
                "code \(code) 必须自带说明文案，不能依赖 fallbackMessage"
            )
        }
    }

    /// DASH 合并器缺失是本地工具链问题，不得再显示成「网络错误」。
    func testDashMergerUnavailableIsNotPresentedAsANetworkError() {
        let friendly = ErrorPresentation.describe(
            code: DASHDownloadError.mergerUnavailable.code,
            fallbackMessage: nil
        )
        XCTAssertTrue(friendly.title.contains("FFmpeg"), "实际标题：\(friendly.title)")
        XCTAssertFalse(friendly.message.contains("网络"), "实际文案：\(friendly.message)")
    }

    /// App 收尾逻辑对未分类错误仍保留 NETWORK_ERROR 兜底：标题必须是本地化
    /// 文案而不是原始 code，正文优先用任务上存下的说明。
    func testGenericNetworkBucketKeepsItsCopy() {
        let friendly = ErrorPresentation.describe(code: "NETWORK_ERROR", fallbackMessage: "自定义说明")
        XCTAssertEqual(friendly.title, "网络错误")
        XCTAssertEqual(friendly.message, "自定义说明")
    }
}
