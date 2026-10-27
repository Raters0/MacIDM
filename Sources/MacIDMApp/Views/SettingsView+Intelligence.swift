import AppKit
import IDMEngine
import SwiftUI

extension SettingsView {
    var browserSection: some View {
        settingsSection("浏览器") {
            settingRow(
                "Chrome 本地通信",
                controlColumnWidth: SettingsMetrics.mediumControlColumn
            ) {
                Label(
                    model.browserBridgeStatus.title,
                    systemImage: model.browserBridgeStatus == .connected
                        ? "checkmark.circle.fill" : "network"
                )
                .foregroundStyle(model.browserBridgeStatus == .connected ? AppTheme.success : Color.secondary)
            }
            if let logURL = model.takeoverLogURL {
                rowDivider
                settingRow(
                    "接管日志",
                    description: "记录浏览器接管的判定过程",
                    controlColumnWidth: SettingsMetrics.mediumControlColumn
                ) {
                    Button("在访达中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([logURL])
                    }
                }
            }
        } footer: {
            if case .failed(let message) = model.browserBridgeStatus {
                Text(message)
                    .foregroundStyle(AppTheme.warning)
            }
        }
    }

    var semanticTitleSection: some View {
        settingsSection("智能命名辅助（实验性）") {
            toggleRow("启用语义判断服务", isOn: $settings.semanticTitleEnabled)
                .onChange(of: settings.semanticTitleEnabled) { enabled in
                    // 首次启用且未填地址：按当前服务商预设填充地址与模型。
                    guard enabled,
                        settings.semanticTitleEndpoint.trimmingCharacters(in: .whitespaces).isEmpty,
                        let preset = SemanticTitleProviderPreset.preset(id: settings.semanticTitleProvider)
                    else { return }
                    settings.semanticTitleEndpoint = preset.endpoint
                    settings.semanticTitleModel = preset.model
                }
            if settings.semanticTitleEnabled {
                rowDivider
                settingRow("服务商") {
                    Picker("", selection: $settings.semanticTitleProvider) {
                        ForEach(SemanticTitleProviderPreset.all) { preset in
                            Text(preset.displayName).tag(preset.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                    .pointerCursorOnHover()
                    .onChange(of: settings.semanticTitleProvider) { raw in
                        // 切换服务商即按预设覆盖地址与模型。
                        if let preset = SemanticTitleProviderPreset.preset(id: raw) {
                            settings.semanticTitleEndpoint = preset.endpoint
                            settings.semanticTitleModel = preset.model
                        }
                    }
                }
                rowDivider
                settingRow("API 地址") {
                    TextField("", text: $settings.semanticTitleEndpoint, prompt: Text("https://…"))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)
                }
                rowDivider
                settingRow("模型") {
                    semanticAdornedField {
                        TextField(
                            "", text: $settings.semanticTitleModel,
                            prompt: Text("模型 id（可点右侧图标获取列表）")
                        )
                    } adornment: {
                        modelListMenu
                    }
                }
                rowDivider
                settingRow("API KEY") {
                    semanticAdornedField {
                        Group {
                            if showSemanticKey {
                                TextField("", text: $semanticAPIKey)
                            } else {
                                SecureField("", text: $semanticAPIKey)
                            }
                        }
                    } adornment: {
                        Button {
                            showSemanticKey.toggle()
                        } label: {
                            Image(systemName: showSemanticKey ? "eye.slash" : "eye")
                                .font(.system(size: 11, weight: .light))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .pointerCursorOnHover()
                        .accessibilityLabel(showSemanticKey ? "隐藏 API KEY" : "显示 API KEY")
                    }
                }
                rowDivider
                settingRow("连接测试") {
                    HStack(spacing: 8) {
                        Button("测试连接") {
                            testSemanticConnection()
                        }
                        .disabled(isTestingSemanticConnection)
                        if isTestingSemanticConnection {
                            ProgressView().controlSize(.small)
                        }
                        if let semanticToolMessage {
                            Text(semanticToolMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
            }
        } footer: {
            if settings.semanticTitleEnabled {
                if settings.semanticTitleEndpoint.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("请选择服务商或填写 API 地址。")
                        .foregroundStyle(AppTheme.warning)
                } else if settings.semanticTitleModel.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("请填写模型 id。")
                        .foregroundStyle(AppTheme.warning)
                } else if !hasStoredSemanticKey {
                    Text("在 API KEY 输入框粘贴 KEY（自动保存到本机钥匙串）后生效。")
                        .foregroundStyle(AppTheme.warning)
                } else {
                    Text("确认窗口先按常规规则给出文件名，仲裁结果仅在高置信时覆盖为建议名，用户编辑永远优先。上送内容仅限候选标题字符串与页面标题，不含媒体 URL、Cookie 或其他凭据。")
                }
            } else {
                Text(
                    "开启后选择服务商（自动填充地址与模型）并粘贴 API KEY（只存本机钥匙串，可下拉获取模型列表、测试连接）并粘贴 API KEY（只存本机钥匙串，输入框内的眼睛图标可查看）。关闭或不可用时完全使用本地命名规则。"
                )
            }
        }
        .onAppear {
            if semanticAPIKey.isEmpty,
                let stored = model.semanticTitleKeychainStore
                    .loadPassword(username: SemanticTitleService.keychainAccount)
            {
                semanticAPIKey = stored
            }
        }
        .onChange(of: semanticAPIKey) { newValue in
            // 输入即存（去抖 300ms）：清空即删除，与常见 Agent 产品的 KEY 填写交互一致。
            semanticKeySaveTask?.cancel()
            let keychain = model.semanticTitleKeychainStore
            semanticKeySaveTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    keychain.delete(username: SemanticTitleService.keychainAccount)
                } else {
                    try? keychain.save(
                        username: SemanticTitleService.keychainAccount,
                        password: trimmed
                    )
                }
            }
        }
    }

    var hasStoredSemanticKey: Bool {
        model.semanticTitleKeychainStore
            .loadPassword(username: SemanticTitleService.keychainAccount) != nil
    }

    /// 自绘「输入框 + 尾部图标」容器：图标占位是实底（与输入框同底色），
    /// 输入文字到图标前截止，不会从图标下方穿过（透明 overlay 的老问题）。
    /// 视觉对齐系统 `.roundedBorder`：text 背景色 + 分隔线描边。
    func semanticAdornedField<
        Field: View,
        Adornment: View
    >(
        @ViewBuilder field: () -> Field,
        @ViewBuilder adornment: () -> Adornment
    ) -> some View {
        HStack(spacing: 0) {
            field()
                .textFieldStyle(.plain)
                .padding(.leading, 7)
            adornment()
                .padding(.horizontal, 6)
        }
        .frame(height: 23)
        .background(Color(nsColor: .textBackgroundColor))
        .cornerRadius(5)
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    /// 「模型」字段内的下拉：首次点开是「获取模型列表」，拉取后变成候选菜单。
    var modelListMenu: some View {
        Menu {
            if isFetchingSemanticModels {
                Text("正在获取模型列表…")
            } else if let models = semanticModels {
                ForEach(models, id: \.self) { model in
                    Button(model) {
                        settings.semanticTitleModel = model
                    }
                }
                Divider()
                Button("重新获取") {
                    fetchSemanticModels()
                }
            } else {
                Button("获取模型列表") {
                    fetchSemanticModels()
                }
            }
        } label: {
            if isFetchingSemanticModels {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .light))
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .pointerCursorOnHover()
    }

    /// 用设置页当前输入值（含未落钥匙串的 KEY）组装请求配置。
    func liveSemanticConfig() -> SemanticTitleConfig? {
        let endpoint = settings.semanticTitleEndpoint.trimmingCharacters(in: .whitespaces)
        let apiKey =
            semanticAPIKey.isEmpty
            ? (model.semanticTitleKeychainStore
                .loadPassword(username: SemanticTitleService.keychainAccount) ?? "")
            : semanticAPIKey
        guard !endpoint.isEmpty, !apiKey.isEmpty else { return nil }
        return SemanticTitleConfig(
            format: SemanticTitleFormat(providerID: settings.semanticTitleProvider),
            endpoint: endpoint,
            model: settings.semanticTitleModel.trimmingCharacters(in: .whitespaces),
            apiKey: apiKey
        )
    }

    func fetchSemanticModels() {
        guard let config = liveSemanticConfig() else {
            semanticToolMessage = "请先填写 API 地址与 KEY"
            return
        }
        isFetchingSemanticModels = true
        Task { @MainActor in
            let result = await model.semanticTitleService.fetchModelList(config: config)
            isFetchingSemanticModels = false
            switch result {
            case .success(let models):
                semanticModels = models
                semanticToolMessage = nil
            case .failure(let detail):
                semanticToolMessage = "获取模型列表失败：\(detail)"
            }
        }
    }

    func testSemanticConnection() {
        guard let config = liveSemanticConfig() else {
            semanticToolMessage = "请先填写 API 地址与 KEY"
            return
        }
        isTestingSemanticConnection = true
        semanticToolMessage = nil
        Task { @MainActor in
            let result = await model.semanticTitleService.testConnection(config: config)
            isTestingSemanticConnection = false
            switch result {
            case .success(let detail):
                semanticToolMessage = "✓ " + detail
            case .failure(let detail):
                semanticToolMessage = "✗ " + detail
            }
        }
    }

}
