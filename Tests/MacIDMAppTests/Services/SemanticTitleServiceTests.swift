import Foundation
import MacIDMBridge
import XCTest

@testable import MacIDMApp

@MainActor
final class SemanticTitleServiceTests: XCTestCase {
    private let candidates = [
        SemanticTitleCandidate(text: "第88集：桑吉尔夫就是现在！让她尝尝你的超级抱抱回吧！", scope: "card"),
        SemanticTitleCandidate(text: "45分钟全程回忆 从抖音开始到现在全会唱的爆火BGM合集", scope: "page"),
        SemanticTitleCandidate(text: "download", scope: "card"),
    ]

    private static let typeSafeEndpoint = "https://api.typesafe.ai/v1/systemone"

    private static func typeSafeResponse(choice: String, confidence: Double) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "model": "jev-1.13.0",
            "answers": [
                "title": ["choice": choice, "confidence": confidence, "probabilities": [:] as [String: Double]]
            ],
        ])
    }

    private static func openAIResponse(choice: String, confidence: Double) -> Data {
        let content = "{\"choice\":\"\(choice)\",\"confidence\":\(confidence)}"
        return try! JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["role": "assistant", "content": content]]]
        ])
    }

    private static func httpOK(_ body: Data) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.typesafe.ai/v1/systemone")!, statusCode: 200,
            httpVersion: nil, headerFields: nil)!
    }

    private static func httpStatus(_ code: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.typesafe.ai/v1/systemone")!, statusCode: code,
            httpVersion: nil, headerFields: nil)!
    }

    private func typeSafeConfig(
        endpoint: String = SemanticTitleServiceTests.typeSafeEndpoint
    ) -> SemanticTitleConfig {
        SemanticTitleConfig(format: .typeSafe, endpoint: endpoint, model: "jev-latest", apiKey: "key")
    }

    private func openAIConfig() -> SemanticTitleConfig {
        SemanticTitleConfig(
            format: .openAICompatible, endpoint: "https://api.deepseek.com",
            model: "deepseek-chat", apiKey: "key"
        )
    }

    private func context(cacheKey: String = "https://media.example/v/1?sig=secret") -> SemanticTitleContext {
        SemanticTitleContext(
            cacheKey: cacheKey, pageHost: "media.example", pageTitle: "页面标题", candidates: candidates
        )
    }

    // MARK: - 请求构造（隐私不变量：签名媒体 URL 绝不出域）

    func testTypeSafeRequestBodyCarriesOnlyCandidatesAndPageMeta() throws {
        let context = SemanticTitleContext(
            cacheKey: "https://media.example/v/1?sig=secret",
            pageHost: "media.example",
            pageTitle: "页面标题",
            candidates: candidates
        )
        let body = SemanticTitleService.typeSafeRequestBody(context: context, model: "jev-latest")
        guard case .object(let state)? = body["state"] else {
            return XCTFail("state must be an object")
        }
        XCTAssertNil(state["url"], "出站 state 不得携带媒体 URL（签名查询参数不出域）")
        guard case .object(let page)? = state["page"] else {
            return XCTFail("state.page must be an object")
        }
        XCTAssertEqual(page["host"], .string("media.example"))
        XCTAssertEqual(page["documentTitle"], .string("页面标题"))
        guard case .array(let listed)? = state["candidates"], listed.count == candidates.count else {
            return XCTFail("state.candidates must list every candidate")
        }
        XCTAssertEqual(
            listed[0],
            .object(["id": .string("k1"), "text": .string(candidates[0].text), "scope": .string("card")])
        )
        guard case .object(let questions)? = body["questions"],
            case .object(let title)? = questions["title"],
            title["type"] == .string("choice"),
            case .object(let criteria)? = title["criteria"]
        else {
            return XCTFail("questions.title must be a choice question with criteria")
        }
        XCTAssertEqual(criteria["k1"], .string(candidates[0].text))
        XCTAssertEqual(criteria["none"], .null, "none 弃权项必须存在且值为 JSON null")
    }

    func testOpenAIRequestBodyCarriesOnlyCandidatesAndPageMeta() throws {
        let context = SemanticTitleContext(
            cacheKey: "https://media.example/v/1?sig=secret",
            pageHost: "media.example",
            pageTitle: "页面标题",
            candidates: candidates
        )
        let body = SemanticTitleService.openAIRequestBody(context: context, model: "glm-4-flash")
        XCTAssertEqual(body["model"] as? String, "glm-4-flash")
        XCTAssertNil(body["url"], "出站请求体不得携带媒体 URL")
        XCTAssertNil(body["state"], "OpenAI 兼容体不使用 TypeSafe 的 state 字段")
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        let userContent = try XCTUnwrap(messages[1]["content"] as? String)
        XCTAssertFalse(userContent.contains("sig=secret"), "缓存键（含签名参数）不得进入出站请求")
        XCTAssertTrue(userContent.contains("k1"))
        XCTAssertTrue(userContent.contains("\"scope\":\"card\""), "OpenAI 兼容体必须携带候选 scope 标记")
        XCTAssertEqual((body["response_format"] as? [String: Any])?["type"] as? String, "json_object")
    }

    // MARK: - 响应解析与采纳策略（两种格式共用同一采纳规则）

    func testDecisionAcceptsHighConfidenceKnownCandidate() {
        let typeSafe = SemanticTitleService.decision(
            from: Self.typeSafeResponse(choice: "k1", confidence: 0.85),
            format: .typeSafe,
            candidates: candidates
        )
        XCTAssertEqual(typeSafe, SemanticTitleDecision(title: candidates[0].text, confidence: 0.85))
        let openAI = SemanticTitleService.decision(
            from: Self.openAIResponse(choice: "k1", confidence: 0.85),
            format: .openAICompatible,
            candidates: candidates
        )
        XCTAssertEqual(openAI, SemanticTitleDecision(title: candidates[0].text, confidence: 0.85))
    }

    func testOpenAIParserToleratesProseWrappedJSON() throws {
        let prose = "好的，结果如下：{\"choice\":\"k2\",\"confidence\":0.9} 以上。"
        let answer = try XCTUnwrap(SemanticTitleService.parseJSONAnswer(fromContent: prose))
        XCTAssertEqual(answer["choice"] as? String, "k2", "前后带说明文字的 JSON 回答必须能截取解析")
        let envelope = try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["role": "assistant", "content": prose]]]
        ])
        let decision = SemanticTitleService.decision(
            from: envelope, format: .openAICompatible, candidates: candidates
        )
        XCTAssertEqual(decision?.title, candidates[1].text)
    }

    func testDecisionAbstainsOnNoneLowConfidenceUnknownIDAndGenericName() {
        for format in [SemanticTitleFormat.typeSafe, .openAICompatible] {
            let response =
                format == .typeSafe
                ? Self.typeSafeResponse(choice: "none", confidence: 0.9)
                : Self.openAIResponse(choice: "none", confidence: 0.9)
            XCTAssertNil(
                SemanticTitleService.decision(from: response, format: format, candidates: candidates),
                "\(format): none 弃权项不得映射成任何标题"
            )
            let lowConfidence =
                format == .typeSafe
                ? Self.typeSafeResponse(choice: "k1", confidence: 0.4)
                : Self.openAIResponse(choice: "k1", confidence: 0.4)
            XCTAssertNil(
                SemanticTitleService.decision(from: lowConfidence, format: format, candidates: candidates),
                "\(format): 低于采纳阈值的答案必须弃权"
            )
            let unknownID =
                format == .typeSafe
                ? Self.typeSafeResponse(choice: "k9", confidence: 0.99)
                : Self.openAIResponse(choice: "k9", confidence: 0.99)
            XCTAssertNil(
                SemanticTitleService.decision(from: unknownID, format: format, candidates: candidates),
                "\(format): 未知候选 id（模型幻觉）不得进入命名链"
            )
            let genericName =
                format == .typeSafe
                ? Self.typeSafeResponse(choice: "k3", confidence: 0.99)
                : Self.openAIResponse(choice: "k3", confidence: 0.99)
            XCTAssertNil(
                SemanticTitleService.decision(from: genericName, format: format, candidates: candidates),
                "\(format): 泛化占位名（download）不得作为语义标题"
            )
        }
        XCTAssertNil(
            SemanticTitleService.decision(
                from: Data("not json".utf8), format: .typeSafe, candidates: candidates
            ),
            "非 JSON 响应必须弃权"
        )
    }

    func testVerdictReportsAbstainReasonsForStructuredLogging() {
        // decision 与 verdict 的行为一致；verdict 额外给出四态日志用的原因。
        XCTAssertEqual(
            SemanticTitleService.verdict(
                from: Self.typeSafeResponse(choice: "k1", confidence: 0.85),
                format: .typeSafe, candidates: candidates
            ).decision?.title,
            candidates[0].text
        )
        for (choice, confidence, expected) in [
            ("none", 0.9, SemanticTitleService.AbstainReason.modelDeclined),
            ("k1", 0.4, SemanticTitleService.AbstainReason.lowConfidence),
            ("k9", 0.99, SemanticTitleService.AbstainReason.unknownCandidate),
            ("k3", 0.99, SemanticTitleService.AbstainReason.genericName),
        ] {
            let verdict = SemanticTitleService.verdict(
                from: Self.typeSafeResponse(choice: choice, confidence: confidence),
                format: .typeSafe, candidates: candidates
            )
            XCTAssertNil(verdict.decision)
            XCTAssertEqual(verdict.reason, expected, "\(choice)@\(confidence) 的弃权原因")
        }
        let unparsed = SemanticTitleService.verdict(
            from: Data("not json".utf8), format: .typeSafe, candidates: candidates
        )
        XCTAssertNil(unparsed.decision)
        XCTAssertEqual(unparsed.reason, .unparsed)
        let adopted = SemanticTitleService.verdict(
            from: Self.openAIResponse(choice: "k2", confidence: 0.9),
            format: .openAICompatible, candidates: candidates
        )
        XCTAssertEqual(adopted.decision?.title, candidates[1].text)
        XCTAssertNil(adopted.reason)
    }

    /// 四态结构化日志：invoke / adopted / abstain / failure 各落一行，且不
    /// 含媒体 URL（cacheKey）与标题文本（Sources/AGENTS.md 诊断数据规则）。
    func testResolveTitleWritesFourStateStructuredLogLines() async {
        let service = SemanticTitleService(configProvider: { self.typeSafeConfig() })
        let adoptedContext = context(cacheKey: "https://media.example/v/log-adopt?sig=secret")
        let adopted = await service.resolveTitle(
            context: adoptedContext,
            transport: { request in
                (Self.typeSafeResponse(choice: "k1", confidence: 0.8), Self.httpOK(Data()))
            }
        )
        XCTAssertEqual(adopted.decision?.title, candidates[0].text)
        let abstainContext = context(cacheKey: "https://media.example/v/log-abstain?sig=secret")
        _ = await service.resolveTitle(
            context: abstainContext,
            transport: { _ in (Self.typeSafeResponse(choice: "none", confidence: 0.9), Self.httpOK(Data())) }
        )
        let unconfigured = SemanticTitleService(configProvider: { nil })
        _ = await unconfigured.resolveTitle(
            context: context(cacheKey: "https://media.example/v/log-fail?sig=secret"),
            transport: { _ in (Data(), Self.httpOK(Data())) }
        )
        let log = AppLogger.shared.readLog()
        XCTAssertTrue(log.contains("semantic-title invoke model=jev-latest"), "invoke 态必须落日志")
        XCTAssertTrue(log.contains("semantic-title adopted confidence=0.80"), "adopted 态必须带置信度")
        XCTAssertTrue(log.contains("semantic-title abstain reason=modelDeclined"), "弃权必须带原因")
        XCTAssertTrue(log.contains("semantic-title failure=unconfigured"), "失败必须落日志")
        XCTAssertFalse(log.contains("sig=secret"), "日志不得包含媒体 URL（含签名参数）")
        XCTAssertFalse(log.contains(candidates[0].text), "日志不得包含候选标题文本")
    }

    // MARK: - 仲裁、缓存与失败提示

    func testResolveTitleAcceptsThenServesCacheByMediaIdentity() async {
        var callCount = 0
        let service = SemanticTitleService(configProvider: { self.typeSafeConfig() })
        let transport: SemanticTitleService.Transport = { [candidates] request in
            callCount += 1
            XCTAssertTrue(request.url?.absoluteString.hasPrefix("https://api.typesafe.ai") == true)
            let bodyText = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            XCTAssertFalse(bodyText.contains("sig=secret"), "缓存键（含签名参数）不得进入出站请求")
            return (Self.typeSafeResponse(choice: "k1", confidence: 0.8), Self.httpOK(Data(bodyText.utf8)))
        }
        let context = context()
        let first = await service.resolveTitle(context: context, transport: transport)
        XCTAssertEqual(first.decision?.title, candidates[0].text)
        XCTAssertNil(first.failure, "正常采纳不算失败")
        let second = await service.resolveTitle(context: context, transport: transport)
        XCTAssertEqual(second.decision?.title, candidates[0].text)
        XCTAssertEqual(callCount, 1, "同一媒体身份必须命中缓存，只调用一次")
    }

    func testResolveTitleCachesAbstentionWithoutFailure() async {
        var callCount = 0
        let service = SemanticTitleService(configProvider: { self.typeSafeConfig() })
        let transport: SemanticTitleService.Transport = { request in
            callCount += 1
            return (Self.typeSafeResponse(choice: "none", confidence: 0.9), Self.httpOK(Data()))
        }
        let context = context()
        let first = await service.resolveTitle(context: context, transport: transport)
        XCTAssertNil(first.decision)
        XCTAssertNil(first.failure, "模型弃权（none）是正常行为，不是服务失败")
        let second = await service.resolveTitle(context: context, transport: transport)
        XCTAssertNil(second.decision)
        XCTAssertEqual(second.resolution, .abstained, "缓存命中的弃权必须仍报告 abstained")
        XCTAssertEqual(callCount, 1, "弃权结果同样按媒体身份缓存")
    }

    // MARK: - 执行结论（确认窗口五态状态提示）

    /// 三态执行结论：采纳 / 弃权 / 失败互不混淆——弃权不是失败，确认窗口
    /// 据此分别显示「已执行但弃权」与「执行失败」（technical-spec §8.1）。
    func testResolveTitleResolutionDistinguishesAdoptedAbstainedAndFailed() async {
        let service = SemanticTitleService(configProvider: { self.typeSafeConfig() })
        let adopted = await service.resolveTitle(
            context: context(cacheKey: "https://media.example/v/res-adopt?sig=secret"),
            transport: { _ in
                (Self.typeSafeResponse(choice: "k1", confidence: 0.85), Self.httpOK(Data()))
            }
        )
        XCTAssertEqual(adopted.resolution, .adopted, "高置信采纳必须报告 adopted")

        let abstained = await service.resolveTitle(
            context: context(cacheKey: "https://media.example/v/res-abstain?sig=secret"),
            transport: { _ in
                (Self.typeSafeResponse(choice: "none", confidence: 0.9), Self.httpOK(Data()))
            }
        )
        XCTAssertEqual(abstained.resolution, .abstained, "模型弃权必须报告 abstained（非失败）")

        let failed = await service.resolveTitle(
            context: context(cacheKey: "https://media.example/v/res-fail?sig=secret"),
            transport: { _ in (Data(), Self.httpStatus(500)) }
        )
        XCTAssertEqual(failed.resolution, .failed, "HTTP 错误必须报告 failed")
    }

    /// 失败也按媒体身份缓存：重复确认同一媒体时不重复发起调用，且执行
    /// 状态与失败简述和首次一致（缓存命中不得漂移成弃权）。
    func testResolveTitleCachesFailureAttemptWithSameStatus() async {
        var callCount = 0
        let service = SemanticTitleService(configProvider: { self.typeSafeConfig() })
        let transport: SemanticTitleService.Transport = { _ in
            callCount += 1
            return (Data(), Self.httpStatus(404))
        }
        let context = context(cacheKey: "https://media.example/v/cache-fail?sig=secret")
        let first = await service.resolveTitle(context: context, transport: transport)
        let second = await service.resolveTitle(context: context, transport: transport)
        XCTAssertEqual(first.failure, "HTTP 404")
        XCTAssertEqual(second.failure, first.failure, "缓存命中的失败简述必须与首次一致")
        XCTAssertEqual(second.resolution, .failed, "重复确认同一媒体时执行状态不得漂移")
        XCTAssertEqual(callCount, 1, "失败也按媒体身份缓存，不重复发起调用")
    }

    func testResolveTitleSurfacesFailuresForConfirmWindowHint() async {
        var unavailableCalls = 0
        let unavailable = SemanticTitleService(configProvider: { self.typeSafeConfig() })
        let unavailableTransport: SemanticTitleService.Transport = { _ in
            unavailableCalls += 1
            return (Data(), Self.httpStatus(404))
        }
        let unavailableOutcome = await unavailable.resolveTitle(
            context: context(), transport: unavailableTransport
        )
        XCTAssertNil(unavailableOutcome.decision)
        XCTAssertEqual(
            unavailableOutcome.failure, "HTTP 404",
            "服务不可用必须给出确认窗口提示所需的失败简述"
        )
        XCTAssertEqual(unavailableCalls, 1)

        var unconfiguredCalls = 0
        let unconfigured = SemanticTitleService(configProvider: { nil })
        let countingTransport: SemanticTitleService.Transport = { _ in
            unconfiguredCalls += 1
            return (Data(), Self.httpStatus(200))
        }
        let unconfiguredOutcome = await unconfigured.resolveTitle(
            context: context(), transport: countingTransport
        )
        XCTAssertNil(unconfiguredOutcome.decision)
        XCTAssertNotNil(unconfiguredOutcome.failure, "功能开启但未完成配置也要提示")
        XCTAssertEqual(unconfiguredCalls, 0, "未配置时不得发起网络调用")
    }

    // MARK: - 模型列表与连接测试

    func testFetchModelListReturnsAliasesForTypeSafeWithoutNetwork() async {
        var callCount = 0
        let service = SemanticTitleService(configProvider: { self.typeSafeConfig() })
        let transport: SemanticTitleService.Transport = { _ in
            callCount += 1
            return (Data(), Self.httpStatus(200))
        }
        let result = await service.fetchModelList(config: typeSafeConfig(), transport: transport)
        XCTAssertEqual(result.get(), ["jev-latest", "jev-preview"], "TypeSafe 无列表端点，返回官方别名")
        XCTAssertEqual(callCount, 0, "TypeSafe 模型清单不得发起网络调用")
    }

    func testFetchModelListQueriesModelsEndpointForOpenAICompatible() async {
        var requestedURL = ""
        let service = SemanticTitleService(configProvider: { self.openAIConfig() })
        let transport: SemanticTitleService.Transport = { request in
            requestedURL = request.url?.absoluteString ?? ""
            let body = try! JSONSerialization.data(withJSONObject: [
                "data": [["id": "glm-4-plus"], ["id": "glm-4-flash"], ["id": "glm-4-air"]]
            ])
            return (body, Self.httpOK(body))
        }
        let result = await service.fetchModelList(config: openAIConfig(), transport: transport)
        XCTAssertEqual(result.get(), ["glm-4-air", "glm-4-flash", "glm-4-plus"], "模型列表必须排序呈现")
        XCTAssertEqual(requestedURL, "https://api.deepseek.com/models")
    }

    func testTestConnectionProbesMinimalRequestAndReportsLatency() async {
        let typeSafe = SemanticTitleService(configProvider: { self.typeSafeConfig() })
        let probeTransport: SemanticTitleService.Transport = { request in
            XCTAssertTrue(request.url?.absoluteString == SemanticTitleServiceTests.typeSafeEndpoint)
            let bodyText = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            XCTAssertTrue(bodyText.contains("连接测试"), "TypeSafe 连接测试发微型仲裁请求")
            return (Self.typeSafeResponse(choice: "ok", confidence: 1.0), Self.httpOK(Data()))
        }
        let probeResult = await typeSafe.testConnection(config: typeSafeConfig(), transport: probeTransport)
        let probeDetail = probeResult.get()
        XCTAssertNotNil(probeDetail)
        XCTAssertTrue(
            probeDetail?.contains("jev-latest") == true,
            "连接测试详情必须带模型名：\(String(describing: probeDetail))"
        )

        let openAI = SemanticTitleService(configProvider: { self.openAIConfig() })
        let modelsTransport: SemanticTitleService.Transport = { request in
            XCTAssertTrue(
                request.url?.absoluteString == "https://api.deepseek.com/models",
                "OpenAI 兼容连接测试用 GET /models"
            )
            let body = try! JSONSerialization.data(withJSONObject: ["data": [["id": "deepseek-chat"]]])
            return (body, Self.httpOK(body))
        }
        let modelsResult = await openAI.testConnection(config: openAIConfig(), transport: modelsTransport)
        let modelsDetail = modelsResult.get()
        XCTAssertTrue(
            modelsDetail?.contains("1 个模型") == true,
            "OpenAI 兼容连接测试详情带模型数：\(String(describing: modelsDetail))"
        )

        let failing = SemanticTitleService(configProvider: { self.typeSafeConfig() })
        let failureResult = await failing.testConnection(
            config: typeSafeConfig(),
            transport: { _ in (Data(), Self.httpStatus(401)) }
        )
        guard case .failure(let failureDetail) = failureResult else {
            return XCTFail("401 必须以失败结束")
        }
        XCTAssertEqual(failureDetail, "HTTP 401")
    }
}
