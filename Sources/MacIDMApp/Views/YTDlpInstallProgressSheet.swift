import SwiftUI

/// Live install/update feedback for yt-dlp: stage, a real progress bar and
/// transferred bytes replace the old single "Processing" alert.
struct YTDlpInstallProgressSheet: View {
    @ObservedObject var model: AppModel

    private var progress: YTDlpManager.InstallProgress? {
        model.ytdlpManager.installProgress
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(stageTitle)
                .font(.title3.bold())
            if let progress, progress.stage == .downloading {
                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                        .tint(AppTheme.accent)
                    HStack {
                        Text(
                            "\(DisplayFormatting.byteCount(progress.receivedBytes)) / \(DisplayFormatting.byteCount(progress.totalBytes))"
                        )
                        Spacer()
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                    }
                    .font(.caption)
                    .monospacedDigit()
                } else {
                    ProgressView()
                    Text("已下载 \(DisplayFormatting.byteCount(progress.receivedBytes))，大小未知")
                        .font(.caption)
                }
                if progress.averageSpeed > 0 {
                    Text("速度 \(DisplayFormatting.speed(progress.averageSpeed))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let progress, progress.stage == .installing {
                ProgressView()
                Text("下载完成，正在安装并验证……")
                    .font(.caption)
            } else {
                ProgressView()
                Text("正在获取最新版本信息……")
                    .font(.caption)
            }
            HStack {
                Spacer()
                Button("后台运行") {
                    model.ytdlpManager.isInstallProgressHidden = true
                }
                .buttonStyle(FlatHoverButtonStyle())
            }
        }
        .padding(22)
        .frame(width: 420)
        .interactiveDismissDisabled()
    }

    private var stageTitle: String {
        switch progress?.stage {
        case .fetchingRelease, nil: "正在准备 yt-dlp"
        case .downloading: "正在下载 yt-dlp"
        case .installing: "正在安装 yt-dlp"
        }
    }
}
