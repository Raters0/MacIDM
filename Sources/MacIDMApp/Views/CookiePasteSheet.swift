import SwiftUI

/// Manual cookie entry sheet. Opened from the session-expiry alert or the
/// new-download advanced options; stores the pasted Cookie header into
/// `SessionStore` and optionally retries the task that triggered it. The paste
/// is the user's https confirmation: the session is recorded as https-scoped
/// and only ever offered to https downloads of exactly this host.
///
/// Fixed-height sheet: the form scrolls above a pinned footer, so expanding
/// the step-by-step guide never pushes the buttons off-screen (an expanding
/// sheet used to grow past the display with no way to scroll). Everything
/// except the two fields lives inside the collapsed-by-default guide, so the
/// resting sheet stays short.
struct CookiePasteSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var domain: String
    @State private var cookieText = ""
    @State private var errorMessage: String?
    /// The step-by-step guide starts collapsed; the disclosure label itself
    /// carries the one-line fetch recipe.
    @State private var isDetailedGuideExpanded = false
    /// The stored cookie last echoed into the editor. While the field still
    /// equals this echo (or both are empty), later domain changes keep
    /// mirroring that site's stored value; anything the user types stops
    /// the echo.
    @State private var lastEchoedCookie: String?
    /// Task to resume right after a successful paste, when the sheet was
    /// opened from a failure alert.
    private let retryTaskID: UUID?

    init(domain: String, retryTaskID: UUID? = nil) {
        _domain = State(initialValue: domain)
        self.retryTaskID = retryTaskID
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("粘贴站点 Cookie")
                        .font(.title2.bold())

                    TextField("站点主机名（如 example.com）", text: $domain)
                        .textFieldStyle(.roundedBorder)
                    Text("与浏览器地址栏中的主机一致；www.example.com 与 example.com 是两个不同的站点。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let stored = storedSessionForDomain {
                        Text(
                            "该站点已保存过 Cookie（更新于 \(stored.updatedAt.formatted(date: .omitted, time: .shortened))）；粘贴新值并保存即会覆盖。"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Cookie 值")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $cookieText)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 130, maxHeight: 200)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color.secondary.opacity(0.3))
                            )
                    }

                    guideDisclosure

                    if isDetailedGuideExpanded {
                        detailedGuide
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(AppTheme.danger)
                    }
                }
                .padding(20)
            }
            .background(LightScrollerConfigurator())

            Divider()

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
            .padding(20)
        }
        .buttonStyle(FlatHoverButtonStyle())
        .frame(width: 520, height: 480)
        .onAppear { echoStoredCookieIfUntouched() }
        .onChange(of: domain) { _ in echoStoredCookieIfUntouched() }
    }

    /// One collapsed line carries the whole fetch recipe; expanding it swaps
    /// the brief path for the click-by-click walkthrough and the scope rules.
    private var guideDisclosure: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                isDetailedGuideExpanded.toggle()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isDetailedGuideExpanded ? 90 : 0))
                Text("如何获取：登录 → F12 → Network → ⌘R 刷新 → 点列表第一行 → 复制 Cookie 值")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursorOnHover()
    }

    /// Click-by-click walkthrough behind the disclosure: names every click,
    /// points at the request most likely to carry a Cookie (the page's own
    /// document request), gives a concrete fallback ladder instead of "try
    /// another request", and closes with the scope rules that used to sit
    /// permanently above the form.
    private var detailedGuide: some View {
        VStack(alignment: .leading, spacing: 8) {
            guideStep(
                "第 1 步 · 先登录，再刷新",
                "在浏览器中正常登录该站点，按 F12（或右键页面选“检查”）打开开发者工具并切到 Network（网络）面板，然后按 ⌘R 刷新一次页面。必须登录之后再刷新，否则发出的请求里没有登录 Cookie。"
            )
            guideStep(
                "第 2 步 · 点击“页面主请求”",
                "刷新后请求列表的第一行通常就是当前页面本身：Name（名称）与地址栏网址一致，Type（类型）列显示 document。它带 Cookie 的概率最高。列表太杂时，点类型栏里的 Doc（文档）按钮只看文档类请求，选最上面一行。"
            )
            guideStep(
                "第 3 步 · 复制 Cookie 值",
                "点开该请求，在右侧 Headers（标头）面板向下滚动到 Request Headers（请求标头）小节，找到 Cookie 一行，复制冒号后面的全部内容。开头的 “Cookie:” 三个字母不用管，保存时会自动去掉。同一站点不同请求带的 Cookie 可能略有差异（个别字段随请求变化），任选一份都可以，关键是包含登录字段（例如 B 站的 SESSDATA）。"
            )
            guideStep(
                "第 4 步 · 第一行没有 Cookie 怎么办",
                "js、css、图片、字体等静态文件请求基本都不带 Cookie，不必逐个去点。把类型栏换成 Fetch/XHR，点击一个名称像接口的请求（常含 api、user、login、info 等字样，且域名与本站相同），在它的 Request Headers 里找 Cookie。"
            )
            guideStep(
                "第 5 步 · 还是找不到",
                "多半是刷新发生在登录之前：重新登录后再刷新一次。若依旧没有，该站点可能不需要 Cookie 或登录状态在别的域名下，改用 Chrome 插件提交下载即可自动携带登录状态，无需手动粘贴。"
            )
            guideStep(
                "作用范围",
                "Cookie 按站点隔离，仅用于该主机的 https 下载（不用于 http 或兄弟子域；由于未实现 Path 属性解析，在同一主机的不同路径下均会复用）。保存后对该站点的解析与下载自动生效。"
            )
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous)
                .stroke(AppTheme.hairline, lineWidth: 1)
        )
    }

    private func guideStep(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The stored session covering the domain currently typed (metadata
    /// only: the cookie value itself is not read for this hint).
    private var storedSessionForDomain: StoredSession? {
        guard let key = SessionDomainPolicy.sessionKey(forHost: domain) else { return nil }
        return model.sessionStore.sessions.first { $0.domain == key }
    }

    /// Mirrors the stored cookie of the typed domain into the editor, so
    /// reopening the sheet shows what is actually saved — the field used to
    /// come back empty and read as "my paste vanished". The echo yields to
    /// user input: once the field differs from the last echo it is left
    /// alone, and a stale echo is cleared before it could be saved under a
    /// different domain.
    private func echoStoredCookieIfUntouched() {
        let untouched =
            cookieText == lastEchoedCookie
            || (lastEchoedCookie == nil && cookieText.isEmpty)
        guard let session = storedSessionForDomain else {
            if untouched { cookieText = "" }
            lastEchoedCookie = nil
            return
        }
        let stored = model.sessionStore.cookieHeader(for: session) ?? ""
        if untouched, cookieText != stored {
            cookieText = stored
        }
        lastEchoedCookie = stored
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
