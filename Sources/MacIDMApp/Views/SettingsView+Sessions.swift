import AppKit
import IDMEngine
import SwiftUI

extension SettingsView {
    /// Collapsed by default: the most recently updated domains plus any
    /// auth-failed session outside that set (expired sessions must never
    /// be hidden just because they are old). Result keeps the store's
    /// domain ordering so expanding only appends rows in place.
    var visibleSessions: [StoredSession] {
        let sessions = model.sessionStore.sessions
        guard !sessionsExpanded, sessions.count > SettingsMetrics.collapsedSessionLimit else {
            return sessions
        }
        let recentDomains = Set(
            sessions
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(SettingsMetrics.collapsedSessionLimit)
                .map(\.domain)
        )
        let expiredDomains = sessions.filter {
            $0.lastAuthFailureAt != nil && !recentDomains.contains($0.domain)
        }
        let visibleDomains = recentDomains.union(expiredDomains.map(\.domain))
        return sessions.filter { visibleDomains.contains($0.domain) }
    }

    /// Computed from the actual visible set, not `count - limit`: collapsed
    /// rows may exceed the limit when expired domains are force-included.
    var hiddenSessionCount: Int {
        max(0, model.sessionStore.sessions.count - visibleSessions.count)
    }

    var showsSessionDisclosure: Bool {
        sessionsExpanded
            ? model.sessionStore.sessions.count > SettingsMetrics.collapsedSessionLimit
            : hiddenSessionCount > 0
    }

    /// Group 1 — the session feature itself: the master toggle and the
    /// manual paste entry point. One intent per row, title + description
    /// on the left, the single most relevant control on the right.
    var sessionControlsSection: some View {
        settingsSection("站点会话") {
            toggleRow(
                "记住站点登录状态（Cookie）",
                description: "在支持的下载中自动复用已保存的站点登录状态。",
                isOn: $settings.rememberSiteSessions
            )
            rowDivider
            settingRow(
                "手动添加会话",
                description: "为某个站点粘贴并保存 Cookie。",
                controlColumnWidth: SettingsMetrics.mediumControlColumn
            ) {
                Button("粘贴 Cookie…") {
                    pasteDomain = CookiePasteDomain(domain: "")
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        } footer: {
            Text("Cookie 按站点隔离，不会跨站复用。")
        }
    }

    /// Group 2 — the saved objects themselves. The count is secondary text
    /// attached to the title; the destructive bulk action is a compact
    /// title-row control; per-object actions remain in ellipsis menus.
    var savedSitesSection: some View {
        settingsSection(
            "已保存的站点",
            titleSuffix: Text("（\(model.sessionStore.sessions.count)）").monospacedDigit(),
            trailingAction: AnyView(clearSessionsButton)
        ) {
            if model.sessionStore.sessions.isEmpty {
                Text("尚未保存任何站点会话")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(Array(visibleSessions.enumerated()), id: \.element.domain) { index, session in
                    if index > 0 { rowDivider }
                    sessionRow(session)
                }
                if showsSessionDisclosure {
                    rowDivider
                    sessionDisclosureRow
                }
            }
        }
    }

    /// Borderless expansion affordance at the end of the visible list.
    /// Deliberately not an outlined button so it never competes with the
    /// paste action or the ellipsis menus.
    var sessionDisclosureRow: some View {
        Button {
            sessionsExpanded.toggle()
        } label: {
            HStack(spacing: 6) {
                if sessionsExpanded {
                    Text("收起")
                } else {
                    Text("显示另外 \(hiddenSessionCount) 个站点")
                }
                Image(systemName: sessionsExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(DisclosureRowButtonStyle())
        .accessibilityValue(sessionsExpanded ? Text("已展开") : Text("已折叠"))
    }

    var clearSessionsButton: some View {
        Button {
            model.sessionStore.removeAll()
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(
                    model.sessionStore.sessions.isEmpty
                        ? Color.secondary.opacity(0.35) : AppTheme.danger
                )
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.sessionStore.sessions.isEmpty)
        .pointerCursorOnHover()
        .help("删除所有站点的已保存 Cookies")
        .accessibilityLabel("删除所有站点的已保存 Cookies")
    }

    /// One saved site: the domain with its expiry note rendered directly
    /// underneath (the note is the domain's own auxiliary state, not a
    /// peer column), a fixed-width timestamp, and a compact ellipsis menu.
    /// Rows without an expiry note stay single-line — no reserved subtitle
    /// slot; the timestamp and menu stay vertically centered regardless.
    func sessionRow(_ session: StoredSession) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.domain)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(session.domain)
                if session.lastAuthFailureAt != nil {
                    Text("可能已过期")
                        .font(.caption)
                        .foregroundStyle(AppTheme.warning)
                        .lineLimit(1)
                }
                if session.scheme == nil {
                    Text("来源协议未确认，重新捕获后才会复用")
                        .font(.caption)
                        .foregroundStyle(AppTheme.warning)
                        .lineLimit(1)
                }
                if model.sessionStore.domainsNeedingReauthorization.contains(session.domain) {
                    Text("未能存入钥匙串，本次运行后需重新粘贴")
                        .font(.caption)
                        .foregroundStyle(AppTheme.warning)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)

            Text(
                session.updatedAt,
                format: .dateTime.month().day().hour().minute()
            )
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(width: SettingsMetrics.sessionDateColumn, alignment: .trailing)

            sessionMenu(for: session)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Per-site actions behind a compact borderless ellipsis menu — two
    /// outlined buttons per row read as an admin data table, not a
    /// settings list. Identical menu labels across rows keep the right
    /// edges strictly aligned; the accessibility label names the domain so
    /// keyboard/VoiceOver users can tell the menus apart.
    func sessionMenu(for session: StoredSession) -> some View {
        Menu {
            Button("复制 Cookie") {
                copySessionCookie(for: session)
            }
            Button("更新 Cookie…") {
                pasteDomain = CookiePasteDomain(domain: session.domain)
            }
            Divider()
            Button("删除", role: .destructive) {
                model.sessionStore.remove(domain: session.domain)
            }
        } label: {
            Image(systemName: copiedSessionDomain == session.domain ? "checkmark" : "ellipsis")
                .foregroundStyle(
                    copiedSessionDomain == session.domain ? AppTheme.success : Color.primary
                )
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .pointerCursorOnHover()
        .accessibilityLabel("管理 \(session.domain) 的站点会话")
        .help("管理站点会话")
    }

    /// Copies the stored cookie header back to the clipboard. The value is
    /// resolved from the secret store when the menu item is clicked; a
    /// session whose credential is gone (Keychain refused or wiped) copies
    /// nothing rather than pasting stale data.
    func copySessionCookie(for session: StoredSession) {
        guard let cookie = model.sessionStore.cookieHeader(for: session),
            !cookie.isEmpty
        else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cookie, forType: .string)
        copiedSessionDomain = session.domain
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copiedSessionDomain == session.domain {
                copiedSessionDomain = nil
            }
        }
    }

    // MARK: - Proxy

    var proxySection: some View {
        settingsSection("代理") {
            toggleRow("启用下载代理", isOn: $settings.proxyEnabled)
            if settings.proxyEnabled {
                rowDivider
                settingRow("类型") {
                    Picker("", selection: $settings.proxyKind) {
                        Text("HTTP").tag(ProxyKind.http)
                        Text("HTTPS").tag(ProxyKind.https)
                        Text("SOCKS5").tag(ProxyKind.socks5)
                    }
                    .labelsHidden()
                    .accessibilityLabel("代理类型")
                    .frame(width: 180)
                    .pointerCursorOnHover()
                }
                rowDivider
                settingRow("主机") {
                    TextField("", text: $settings.proxyHost, prompt: Text("如 127.0.0.1"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }
                rowDivider
                settingRow("端口") {
                    Stepper(value: $settings.proxyPort, in: 1...65_535) {
                        Text("\(settings.proxyPort)")
                            .monospacedDigit()
                    }
                    .pointerCursorOnHover()
                }
                rowDivider
                settingRow("用户名（可选）") {
                    TextField("", text: $settings.proxyUsername)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }
                if !settings.proxyUsername.isEmpty {
                    rowDivider
                    settingRow("密码") {
                        SecureField("", text: $proxyPassword)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 260)
                    }
                    rowDivider
                    settingRow("密码存储") {
                        HStack(spacing: 8) {
                            Button(proxyPassword.isEmpty ? "删除已存密码" : "保存密码到 Keychain") {
                                saveProxyCredential()
                            }
                            .disabled(proxyPassword.isEmpty && !hasStoredProxyPassword)
                            if let message = proxyCredentialMessage {
                                Text(message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        } footer: {
            if settings.proxyEnabled {
                if settings.proxyConfiguration == nil {
                    Text("当前主机/端口无效，代理未生效。")
                        .foregroundStyle(AppTheme.warning)
                } else {
                    Text("仅支持 HTTP/HTTPS 代理的 Basic 认证；SOCKS5 尽力而为；Digest/NTLM/Kerberos 不支持。")
                }
            }
        }
    }

    var hasStoredProxyPassword: Bool {
        model.keychainCredentialStore.loadPassword(username: settings.proxyUsername) != nil
    }

    func saveProxyCredential() {
        let username = settings.proxyUsername
        if proxyPassword.isEmpty {
            model.keychainCredentialStore.delete(username: username)
            proxyCredentialMessage = String(localized: "已删除 Keychain 中的密码。")
            return
        }
        do {
            try model.keychainCredentialStore.save(username: username, password: proxyPassword)
            proxyPassword = ""
            proxyCredentialMessage = String(localized: "密码已存入 Keychain。")
            model.rebuildProxyPolicy()
        } catch {
            proxyCredentialMessage = error.localizedDescription
        }
    }

}

/// Borderless hover treatment for the saved-sites disclosure row: no
/// outline, just a faint fill plus an accent-tinted label on hover, so the
/// row reads as a list affordance instead of a peer of the outlined
/// action buttons.
struct DisclosureRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DisclosureRowLabel(configuration: configuration)
    }
}

struct DisclosureRowLabel: View {
    let configuration: DisclosureRowButtonStyle.Configuration
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .foregroundStyle(isHovering || configuration.isPressed ? AppTheme.accent : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(isHovering || configuration.isPressed ? 0.04 : 0))
            )
            .contentShape(Rectangle())
            .pointerCursorOnHover()
            .onHover { isHovering = $0 }
    }
}
