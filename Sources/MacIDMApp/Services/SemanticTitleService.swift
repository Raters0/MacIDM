import Foundation
import MacIDMBridge

/// 用户自配的「语义判断服务」（technical-spec §8.1）：确认窗口打开时，对扩展
/// 随 `download.enqueue` 上送的候选标题做一次「哪个字符串是该媒体的标题」的
/// 语义仲裁。默认关闭；API KEY 只从 Keychain 读取；请求内容只含候选字符串与
/// 页级标题/host，绝不含媒体 URL（签名查询参数不出域）。
///
/// 采纳规则：选项非 `none`、置信度 ≥ 0.7、结果非泛化占位名时返回决策；`none`、
/// 低置信、超时、配额/网络/格式错误一律返回 nil，由确认窗口沿用常规命名链并
/// 按 ``SemanticTitleResolution`` 显示对应执行状态（technical-spec §8.1）。
@MainActor
final class SemanticTitleService: ObservableObject {
    static let keychainAccount = "semantic-title-api-key"
    static let adoptionThreshold = 0.7
    static let cacheLimit = 200

    /// Async because resolving the KEY reads the Keychain, which can raise the
    /// system approval dialog; see ``KeychainAccessSignal``.
    private let configProvider: () async -> SemanticTitleConfig?
    private let urlSession: URLSession
    private let timeout: TimeInterval

    /// 会话级缓存：同一媒体（URL 身份）只调用一次；弃权与失败的 attempt
    /// 同样命中缓存——重复确认同一媒体时，确认窗口的执行状态提示与首次
    /// 一致，且不会重复发起调用。
    private struct CacheEntry {
        let decision: SemanticTitleDecision?
        let failure: String?
    }

    private var cache: [String: CacheEntry] = [:]
    private var cacheOrder: [String] = []

    init(
        configProvider: @MainActor @escaping () async -> SemanticTitleConfig?,
        urlSession: URLSession = .shared,
        timeout: TimeInterval = 8
    ) {
        self.configProvider = configProvider
        self.urlSession = urlSession
        self.timeout = timeout
    }

    /// 仲裁入口。`transport` 供测试注入；生产为 `urlSession.data(for:)`。
    /// 返回 `(decision, failure)`：`decision` 为采纳的标题（其余一律 nil）；
    /// `failure` 只在**服务调用失败**（未完成配置 / HTTP 错误 / 网络异常）时
    /// 非空，供确认窗口提示「已沿用常规命名」——模型弃权（none/低置信）是
    /// 正常行为，不算失败。`resolution` 由二者推导执行结论，确认窗口据此
    /// 显示五态状态提示（technical-spec §8.1）；缓存命中返回首次的完整
    /// attempt，重复确认同一媒体时状态一致且不重复发起调用。
    func resolveTitle(
        context: SemanticTitleContext,
        transport: Transport? = nil
    ) async -> SemanticTitleAttempt {
        guard !context.candidates.isEmpty else { return .init(decision: nil, failure: nil) }
        if let cached = cachedAttempt(forKey: context.cacheKey) {
            return cached
        }
        guard let config = await configProvider(), isConfigured(config) else {
            remember(
                .init(decision: nil, failure: String(localized: "未完成配置（API 地址 / 模型 / KEY）")), forKey: context.cacheKey)
            Self.logSemanticTitle("failure=unconfigured", context: context)
            return .init(decision: nil, failure: String(localized: "未完成配置（API 地址 / 模型 / KEY）"))
        }

        guard let request = Self.makeRequest(config: config, context: context) else {
            remember(.init(decision: nil, failure: String(localized: "API 地址无效（仅支持 HTTPS）")), forKey: context.cacheKey)
            Self.logSemanticTitle("failure=invalid-endpoint", context: context)
            return .init(decision: nil, failure: String(localized: "API 地址无效（仅支持 HTTPS）"))
        }

        Self.logSemanticTitle("invoke model=\(config.model)", context: context)
        do {
            let (data, response) = try await perform(request, transport: transport)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                remember(.init(decision: nil, failure: "HTTP \(status)"), forKey: context.cacheKey)
                Self.logSemanticTitle("failure=http-\(status)", context: context)
                return .init(decision: nil, failure: "HTTP \(status)")
            }
            let verdict = Self.verdict(
                from: data,
                format: config.format,
                candidates: context.candidates,
                threshold: Self.adoptionThreshold
            )
            guard let decision = verdict.decision else {
                remember(.init(decision: nil, failure: nil), forKey: context.cacheKey)
                Self.logSemanticTitle(
                    "abstain reason=\(verdict.reason?.rawValue ?? "unknown")",
                    context: context
                )
                return .init(decision: nil, failure: nil)
            }
            remember(.init(decision: decision, failure: nil), forKey: context.cacheKey)
            Self.logSemanticTitle(
                "adopted confidence=\(String(format: "%.2f", decision.confidence))",
                context: context
            )
            return .init(decision: decision, failure: nil)
        } catch {
            let failure = Self.networkFailureDetail(error)
            remember(.init(decision: nil, failure: failure), forKey: context.cacheKey)
            let detail = (error as? URLError)?.localizedDescription ?? error.localizedDescription
            Self.logSemanticTitle("failure=network error=\(detail)", context: context)
            return .init(decision: nil, failure: failure)
        }
    }

    /// 拉取模型列表（设置页「模型」字段的下拉来源）。TypeSafe 无列表端点，
    /// 返回官方模型别名；OpenAI 兼容走 `GET {base}/models`。
    func fetchModelList(
        config: SemanticTitleConfig,
        transport: Transport? = nil
    ) async -> SemanticTitleOutcome<[String]> {
        switch config.format {
        case .typeSafe:
            return .success(["jev-latest", "jev-preview"])
        case .openAICompatible:
            guard let request = Self.modelsRequest(config: config) else {
                return .failure(String(localized: "API 地址无效（仅支持 HTTPS）"))
            }
            do {
                let (data, response) = try await perform(request, transport: transport)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                    return .failure("HTTP \(status)")
                }
                guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let items = payload["data"] as? [[String: Any]]
                else {
                    return .failure(String(localized: "响应格式无法解析（期望 data[].id）"))
                }
                let ids = items.compactMap { $0["id"] as? String }.sorted()
                guard !ids.isEmpty else { return .failure(String(localized: "服务未返回任何模型")) }
                return .success(ids)
            } catch {
                return .failure(Self.networkFailureDetail(error))
            }
        }
    }

    /// 连接测试：用最小请求验证 endpoint + KEY + model 可用（设置页按钮）。
    /// TypeSafe 发一次微型 choice 仲裁；OpenAI 兼容直接 GET /models。
    func testConnection(
        config: SemanticTitleConfig,
        transport: Transport? = nil
    ) async -> SemanticTitleOutcome<String> {
        let startedAt = Date()
        switch config.format {
        case .typeSafe:
            guard let request = Self.typeSafeProbeRequest(config: config) else {
                return .failure(String(localized: "API 地址无效（仅支持 HTTPS）"))
            }
            do {
                let (_, response) = try await perform(request, transport: transport)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                    return .failure("HTTP \(status)")
                }
                return .success(Self.latencyDetail(startedAt, model: config.model, extra: nil))
            } catch {
                return .failure(Self.networkFailureDetail(error))
            }
        case .openAICompatible:
            let models = await fetchModelList(config: config, transport: transport)
            switch models {
            case .success(let ids):
                return .success(
                    Self.latencyDetail(startedAt, model: config.model, extra: String(localized: "\(ids.count) 个模型")))
            case .failure(let detail):
                return .failure(detail)
            }
        }
    }

    // MARK: - Policy (pure; Swift 测试锁定)

    /// 弃权/解析失败的原因细分：`decision` 行为不变，`verdict` 额外给出原
    /// 因供结构化日志区分四态（adopted / abstain / failure / invoke）。
    enum AbstainReason: String, Sendable {
        case modelDeclined
        case lowConfidence
        case genericName
        case invalidLength
        case unknownCandidate
        case unparsed
    }

    /// TypeSafe System One 请求体：state 摄取一次，候选按 `k1…kn` 编号并附
    /// `none` 弃权项。注意 state 内没有 URL 字段——缓存键与出站内容严格分离。
    static func typeSafeRequestBody(
        context: SemanticTitleContext,
        model: String
    ) -> [String: JSONValue] {
        let numbered = numberedCandidates(context.candidates)
        var criteria: [String: JSONValue] = [:]
        for item in numbered { criteria[item.id] = .string(item.text) }
        criteria["none"] = .null
        return [
            "model": .string(model),
            "state": .object([
                "page": .object([
                    "host": .string(context.pageHost ?? ""),
                    "documentTitle": .string(context.pageTitle ?? ""),
                ]),
                "candidates": .array(
                    numbered.map {
                        .object([
                            "id": .string($0.id),
                            "text": .string($0.text),
                            "scope": .string($0.scope),
                        ])
                    }),
            ]),
            "questions": .object([
                "title": .object([
                    "type": .string("choice"),
                    "instructions": .string(judgmentInstructions),
                    "criteria": .object(criteria),
                ])
            ]),
        ]
    }

    /// OpenAI 兼容（chat/completions）请求体：判断规则进 system 提示词，候选
    /// state 进 user 消息，要求模型只回一个 JSON 对象。同样不含媒体 URL。
    static func openAIRequestBody(
        context: SemanticTitleContext,
        model: String
    ) -> [String: Any] {
        let numbered = numberedCandidates(context.candidates)
        let state: [String: Any] = [
            "page": [
                "host": context.pageHost ?? "",
                "documentTitle": context.pageTitle ?? "",
            ],
            "candidates": numbered.map { ["id": $0.id, "text": $0.text, "scope": $0.scope] },
        ]
        guard let stateJSON = try? JSONSerialization.data(withJSONObject: state),
            let stateText = String(data: stateJSON, encoding: .utf8)
        else { return [:] }
        let system =
            judgmentInstructions
            + " Respond with ONLY a JSON object of the form "
            + "{\"choice\":\"<candidate-id-or-none>\",\"confidence\":<number between 0 and 1>}."
        return [
            "model": model,
            "temperature": 0,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": stateText],
            ],
        ]
    }

    /// 从 TypeSafe 响应解析决策：choice 必须是候选编号之一（按 id 映射回候选
    /// 文本，模型无法引入候选之外的字符串），`none`、未知 id、低置信、泛化占
    /// 位名一律弃权。
    static func decision(
        from data: Data,
        format: SemanticTitleFormat,
        candidates: [SemanticTitleCandidate],
        threshold: Double = SemanticTitleService.adoptionThreshold
    ) -> SemanticTitleDecision? {
        verdict(from: data, format: format, candidates: candidates, threshold: threshold).decision
    }

    /// 带原因的仲裁：`decision` 与 `decision(from:)` 完全一致，`reason` 供
    /// 结构化日志区分弃权原因（采纳时为 nil）。
    static func verdict(
        from data: Data,
        format: SemanticTitleFormat,
        candidates: [SemanticTitleCandidate],
        threshold: Double = SemanticTitleService.adoptionThreshold
    ) -> (decision: SemanticTitleDecision?, reason: AbstainReason?) {
        switch format {
        case .typeSafe:
            guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let answers = payload["answers"] as? [String: Any],
                let titleAnswer = answers["title"] as? [String: Any],
                let choiceID = titleAnswer["choice"] as? String,
                let confidence = (titleAnswer["confidence"] as? NSNumber)?.doubleValue
            else { return (nil, .unparsed) }
            return acceptVerdict(
                choiceID: choiceID, confidence: confidence,
                candidates: candidates, threshold: threshold
            )
        case .openAICompatible:
            guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let choices = payload["choices"] as? [[String: Any]],
                let message = choices.first?["message"] as? [String: Any],
                let content = message["content"] as? String
            else { return (nil, .unparsed) }
            guard let answer = Self.parseJSONAnswer(fromContent: content),
                let choiceID = answer["choice"] as? String,
                let confidence = (answer["confidence"] as? NSNumber)?.doubleValue
            else { return (nil, .unparsed) }
            return acceptVerdict(
                choiceID: choiceID, confidence: confidence,
                candidates: candidates, threshold: threshold
            )
        }
    }

    private static func acceptVerdict(
        choiceID: String,
        confidence: Double,
        candidates: [SemanticTitleCandidate],
        threshold: Double
    ) -> (SemanticTitleDecision?, AbstainReason?) {
        guard choiceID != "none" else { return (nil, .modelDeclined) }
        guard choiceID.hasPrefix("k"),
            let index = Int(choiceID.dropFirst()), (1...candidates.count).contains(index)
        else { return (nil, .unknownCandidate) }
        guard confidence >= threshold else { return (nil, .lowConfidence) }
        let text = candidates[index - 1].text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2, text.count <= 200 else { return (nil, .invalidLength) }
        guard !DownloadNaming.isGenericFilename(text) else { return (nil, .genericName) }
        return (SemanticTitleDecision(title: text, confidence: confidence), nil)
    }

    /// OpenAI 兼容回答的容错解析：优先整体 JSON，失败则截取首个 `{` 到最后
    /// 一个 `}` 之间的片段（部分网关会给回答包上说明文字）。
    static func parseJSONAnswer(fromContent content: String) -> [String: Any]? {
        if let payload = try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any] {
            return payload
        }
        guard let start = content.firstIndex(of: "{"), let end = content.lastIndex(of: "}"),
            start < end
        else { return nil }
        let fragment = String(content[start...end])
        return try? JSONSerialization.jsonObject(with: Data(fragment.utf8)) as? [String: Any]
    }

    // MARK: - internals

    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)

    private static let judgmentInstructions =
        "The state describes one webpage where the user is about to download a "
        + "media item. Decide which candidate string is the title of that media "
        + "item — the name a person would naturally use for the downloaded file. "
        + "Judge only by the candidate strings; the site or platform name and any "
        + "slogan are never a title. Caption strings that mix a title with topic "
        + "hashtags still count as the title. The candidate ids are `k1`, `k2`, …; "
        + "pick exactly one candidate id. Pick `none` only when no candidate is "
        + "the media's title."

    private static func numberedCandidates(
        _ candidates: [SemanticTitleCandidate]
    ) -> [(id: String, text: String, scope: String)] {
        candidates.enumerated().map { index, candidate in
            (id: "k\(index + 1)", text: candidate.text, scope: candidate.scope)
        }
    }

    /// 组装出站请求（internal 供测试锁定 HTTPS 与路径归一化规则）。
    static func makeRequest(
        config: SemanticTitleConfig,
        context: SemanticTitleContext
    ) -> URLRequest? {
        var endpoint = config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard endpoint.lowercased().hasPrefix("https://") else { return nil }
        switch config.format {
        case .typeSafe:
            // endpoint 即完整 API 地址。
            break
        case .openAICompatible:
            // endpoint 是 base 地址；补齐 chat/completions 路径。
            if !endpoint.hasSuffix("/chat/completions") {
                while endpoint.hasSuffix("/") { endpoint.removeLast() }
                endpoint += "/chat/completions"
            }
        }
        guard let url = URL(string: endpoint), url.host != nil else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: Data?
        switch config.format {
        case .typeSafe:
            body = try? JSONEncoder().encode(typeSafeRequestBody(context: context, model: config.model))
        case .openAICompatible:
            body = try? JSONSerialization.data(withJSONObject: openAIRequestBody(context: context, model: config.model))
        }
        guard let body, !body.isEmpty else { return nil }
        request.httpBody = body
        return request
    }

    /// OpenAI 兼容的模型列表请求：`GET {base}/models`。
    static func modelsRequest(config: SemanticTitleConfig) -> URLRequest? {
        var endpoint = config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard endpoint.lowercased().hasPrefix("https://") else { return nil }
        while endpoint.hasSuffix("/") { endpoint.removeLast() }
        guard let url = URL(string: endpoint + "/models"), url.host != nil else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// TypeSafe 连接测试：微型 choice 仲裁（state 是一句话，无候选）。
    static func typeSafeProbeRequest(config: SemanticTitleConfig) -> URLRequest? {
        let endpoint = config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard endpoint.lowercased().hasPrefix("https://"), let url = URL(string: endpoint), url.host != nil else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: JSONValue] = [
            "model": .string(config.model),
            "state": .string("连接测试"),
            "questions": .object([
                "ping": .object([
                    "type": .string("choice"),
                    "instructions": .string("Connectivity probe; always pick `ok`."),
                    "criteria": .object(["ok": .null]),
                ])
            ]),
        ]
        request.httpBody = try? JSONEncoder().encode(body)
        guard request.httpBody != nil else { return nil }
        return request
    }

    private static func networkFailureDetail(_ error: Error) -> String {
        let description = (error as? URLError)?.localizedDescription ?? error.localizedDescription
        return String(localized: "网络错误：\(description)")
    }

    private static func latencyDetail(_ startedAt: Date, model: String, extra: String?) -> String {
        let milliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
        let suffix = extra.map { " · \($0)" } ?? ""
        return "\(model) · \(milliseconds)ms\(suffix)"
    }

    /// 结构化日志（Sources/AGENTS.md 诊断数据规则）：只记结构——模型、候选
    /// 数、置信度、原因、host；不记媒体 URL（cacheKey）与标题文本。四态：
    /// invoke / adopted / abstain / failure，与确认窗口提示同源。
    private static func logSemanticTitle(_ line: String, context: SemanticTitleContext) {
        let host = context.pageHost ?? "-"
        AppLogger.shared.info(
            .naming,
            "semantic-title \(line) candidates=\(context.candidates.count) host=\(host)"
        )
    }

    private func isConfigured(_ config: SemanticTitleConfig) -> Bool {
        !config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !config.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func perform(
        _ request: URLRequest,
        transport: Transport?
    ) async throws -> (Data, URLResponse) {
        if let transport { return try await transport(request) }
        return try await urlSession.data(for: request)
    }

    private func cachedAttempt(forKey key: String) -> SemanticTitleAttempt? {
        guard let entry = cache[key] else { return nil }
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        return SemanticTitleAttempt(decision: entry.decision, failure: entry.failure)
    }

    private func remember(_ attempt: SemanticTitleAttempt, forKey key: String) {
        store(attempt, forKey: key)
    }

    private func store(_ attempt: SemanticTitleAttempt, forKey key: String) {
        if cache[key] == nil { cacheOrder.append(key) }
        cache[key] = CacheEntry(decision: attempt.decision, failure: attempt.failure)
        while cacheOrder.count > Self.cacheLimit {
            let evicted = cacheOrder.removeFirst()
            cache.removeValue(forKey: evicted)
        }
    }
}

/// 语义判断服务的一次请求配置（由设置页与 Keychain 组装）。
struct SemanticTitleConfig: Sendable, Equatable {
    let format: SemanticTitleFormat
    let endpoint: String
    let model: String
    let apiKey: String
}

enum SemanticTitleFormat: String, Sendable {
    /// TypeSafe System One（`POST /v1/systemone`，typed choice 答案）。
    case typeSafe
    /// OpenAI 兼容 chat/completions + 仅 JSON 回答（智谱/DeepSeek/OpenAI 等）。
    case openAICompatible

    init(providerID: String) {
        self = SemanticTitleProviderPreset.preset(id: providerID)?.format ?? .openAICompatible
    }
}

/// 服务商预设：选中后由设置页填充 endpoint 与默认模型（technical-spec §8.1）。
/// 专用「System One」判断模型 API 目前只有 TypeSafe；其余主流厂商走
/// OpenAI 兼容接口，用同一适配器接入。
struct SemanticTitleProviderPreset: Identifiable, Sendable, Equatable {
    let id: String
    let displayName: String
    let format: SemanticTitleFormat
    let endpoint: String
    let model: String

    static let all: [SemanticTitleProviderPreset] = [
        SemanticTitleProviderPreset(
            id: "typeSafe", displayName: "TypeSafe（Jev）", format: .typeSafe,
            endpoint: "https://api.typesafe.ai/v1/systemone", model: "jev-latest"
        ),
        SemanticTitleProviderPreset(
            id: "zhipu", displayName: String(localized: "智谱 GLM（GLM-Flash）"), format: .openAICompatible,
            endpoint: "https://open.bigmodel.cn/api/paas/v4", model: "glm-4-flash"
        ),
        SemanticTitleProviderPreset(
            id: "deepseek", displayName: "DeepSeek", format: .openAICompatible,
            endpoint: "https://api.deepseek.com", model: "deepseek-chat"
        ),
        SemanticTitleProviderPreset(
            id: "openai", displayName: "OpenAI", format: .openAICompatible,
            endpoint: "https://api.openai.com/v1", model: "gpt-4o-mini"
        ),
        SemanticTitleProviderPreset(
            id: "custom", displayName: String(localized: "自定义（OpenAI 兼容）"), format: .openAICompatible,
            endpoint: "", model: ""
        ),
    ]

    static func preset(id: String) -> SemanticTitleProviderPreset? {
        all.first { $0.id == id }
    }
}

/// 轻量结果类型：失败原因是一句给人看的简述，不是可编程 Error。
enum SemanticTitleOutcome<Value: Sendable>: Sendable {
    case success(Value)
    case failure(String)

    func get() -> Value? {
        if case .success(let value) = self { return value }
        return nil
    }
}

/// 仲裁请求上下文。`cacheKey` 用媒体 URL 身份，但**不会**出现在出站请求
/// 里——出站内容只有候选字符串与页级标题/host。
struct SemanticTitleContext: Sendable, Equatable {
    let cacheKey: String
    let pageHost: String?
    let pageTitle: String?
    let candidates: [SemanticTitleCandidate]
}

/// 扩展上送的候选标题（technical-spec §8.1）：scope=card 是用户悬停的锚定
/// 卡片，page 是页面级上下文（og/doc 标题、同页其他卡片标题）。
struct SemanticTitleCandidate: Sendable, Equatable {
    let text: String
    let scope: String
}

struct SemanticTitleDecision: Sendable, Equatable {
    let title: String
    let confidence: Double
}

/// 仲裁执行结论（technical-spec §8.1 执行状态提示）：与 `decision`/`failure`
/// 正交——`decision` 非空即采纳，`failure` 非空即失败，其余为已执行但弃权。
/// 确认窗口据此显示「已执行并采纳 / 已执行但弃权 / 执行失败」，与视图侧
/// 「未执行」合成完整五态状态提示。
enum SemanticTitleResolution: String, Sendable, Equatable {
    /// 已调用模型并采纳高置信标题。
    case adopted
    /// 已调用模型但弃权：`none`/低置信/未知 id/泛化名/长度不符/无法解析。
    case abstained
    /// 服务调用失败：未配置 / 地址无效 / HTTP / 网络。
    case failed
}

/// `resolveTitle` 的结果：`decision` 为采纳的标题；`failure` 为服务调用
/// 失败（配置/HTTP/网络）的简述，供确认窗口提示「已沿用常规命名」；
/// `resolution` 推导执行结论，缓存命中时同样成立。
struct SemanticTitleAttempt: Sendable, Equatable {
    let decision: SemanticTitleDecision?
    let failure: String?

    var resolution: SemanticTitleResolution {
        if decision != nil { return .adopted }
        if failure != nil { return .failed }
        return .abstained
    }
}
