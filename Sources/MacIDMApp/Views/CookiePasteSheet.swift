import SwiftUI

/// Manual cookie entry sheet. Opened from the session-expiry alert or the
/// new-download advanced options; stores the pasted Cookie header into
/// `SessionStore` and optionally retries the task that triggered it. The paste
/// is the user's https confirmation: the session is recorded as https-scoped
/// and only ever offered to https downloads of exactly this host.
struct CookiePasteSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var domain: String
    @State private var cookieText = ""
    @State private var errorMessage: String?
    /// Task to resume right after a successful paste, when the sheet was
    /// opened from a failure alert.
    private let retryTaskID: UUID?

    init(domain: String, retryTaskID: UUID? = nil) {
        _domain = State(initialValue: domain)
        self.retryTaskID = retryTaskID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("粘贴站点 Cookie")
                .font(.title2.bold())
            Text(
                "Cookie 按站点隔离，仅用于该主机的 https 下载（不用于 http 或兄弟子域；由于未实现 Path 属性解析，在同一主机的不同路径下均会复用）。获取方式：在浏览器中登录该站点，按 F12 打开开发者工具 → Network → 刷新页面 → 点击任意请求 → 在 Request Headers 中复制 Cookie 的值。"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            TextField("站点域名（如 example.com）", text: $domain)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 4) {
                Text("Cookie 值")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextEditor(text: $cookieText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 120, maxHeight: 200)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.secondary.opacity(0.3))
                    )
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(AppTheme.danger)
            }

            HStack {
                Spacer()
                Button("取消") {
                    model.requestDismissCookiePasteSheet()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .buttonStyle(FlatHoverButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(domain.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .buttonStyle(FlatHoverButtonStyle())
        .padding(20)
        .frame(width: 520)
    }

    private func save() {
        let trimmedDomain = domain.trimmingCharacters(in: .whitespaces)
        let trimmedCookie = cookieText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCookie.isEmpty else {
            errorMessage = String(localized: "Cookie 值不能为空。")
            return
        }
        guard trimmedCookie.contains("=") else {
            errorMessage = String(
                localized: "Cookie 格式看起来不正确（应包含 name=value 形式的键值对）。"
            )
            return
        }
        switch model.submitManualCookie(
            domain: trimmedDomain,
            cookie: trimmedCookie,
            userAgent: nil,
            retryTaskID: retryTaskID
        ) {
        case .stored:
            dismiss()
        case .emptyCookie:
            errorMessage = String(localized: "Cookie 值不能为空。")
        case .rejectedScheme:
            errorMessage = String(localized: "站点会话仅用于 https 下载。")
        case .rejectedDomain:
            errorMessage = String(
                localized: "域名无法作为站点会话保存，请填写完整主机名（例如 example.com）。"
            )
        case .secretStorageFailed(let message):
            errorMessage = String(localized: "无法保存到钥匙串：\(message)")
        }
    }
}
