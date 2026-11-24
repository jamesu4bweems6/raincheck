import Foundation
import XCTest
@testable import RainCheck

final class CheckInOrchestratorTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeAccount(
        id: String = "acc-1",
        label: String = "张三",
        host: String = "www.yuketang.cn",
        scheme: String = "https",
        bearer: String? = "token-initial-1",
        sessionId: String? = nil,
        csrfToken: String? = nil,
        enabled: Bool = true
    ) -> Account {
        Account(
            id: id,
            label: label,
            host: host,
            scheme: scheme,
            bearer: bearer,
            sessionId: sessionId,
            csrfToken: csrfToken,
            enabled: enabled
        )
    }

    private func makeOrchestrator(
        profile: ProtocolProfile,
        maxAttemptsPerStrategy: Int = 2,
        baseBackoffMs: UInt64 = 0,
        staggerMs: UInt64 = 0,
        handler: @escaping @Sendable (URLRequest) throws -> MockHTTPResponse
    ) -> CheckInOrchestrator {
        let session = MockNetworkSupport.makeSession(handler: handler)
        let client = RainCheckClient(session: session, profile: profile)
        return CheckInOrchestrator(
            client: client,
            profile: profile,
            maxAttemptsPerStrategy: maxAttemptsPerStrategy,
            baseBackoffMs: baseBackoffMs,
            staggerMs: staggerMs
        )
    }

    // MARK: - Strategy Fallback Chain

    func testStrategyFallbackDynTicket14To5ToLessonDesktop() async throws {
        let profile = try TestBundleResources.loadProtocolProfile()
        let ticket = QrCodeParser.parse("c=abc123&t=1763900000&s=sig1&v=2&lessonId=999", profile: profile)

        // 1) DYN_TICKET_14 被拒绝 -> 回退 DYN_TICKET_5 成功
        let seenSourcesFirst = LockedBox<[Int]>([])
        let orchestrator1 = makeOrchestrator(profile: profile) { request in
            let json = MockNetworkSupport.requestBodyJSON(from: request)
            let source = json?["source"]?.intValue ?? -1
            seenSourcesFirst.withLock { $0.append(source) }
            if source == 14 {
                return .json(200, #"{"code":40002,"msg":"桌面端来源被禁用"}"#)
            }
            if source == 5 {
                return .json(200, #"{"code":0,"msg":"签到成功"}"#)
            }
            return .json(200, #"{"code":40002,"msg":"策略拒绝"}"#)
        }

        let res1 = await orchestrator1.checkIn(account: makeAccount(), ticket: ticket)
        XCTAssertEqual(res1.state, .success)
        XCTAssertEqual(res1.strategyId, "DYN_TICKET_5")
        XCTAssertEqual(seenSourcesFirst.get(), [14, 5])
        XCTAssertEqual(res1.attempts.map(\.strategyId), ["DYN_TICKET_14", "DYN_TICKET_5"])

        // 2) DYN_TICKET_14 与 DYN_TICKET_5 均失败 -> 继续回退 LESSON_DESKTOP (source=1) 成功
        let seenSourcesSecond = LockedBox<[Int]>([])
        let orchestrator2 = makeOrchestrator(profile: profile) { request in
            let json = MockNetworkSupport.requestBodyJSON(from: request)
            let source = json?["source"]?.intValue ?? -1
            seenSourcesSecond.withLock { $0.append(source) }
            if source == 14 || source == 5 {
                return .json(200, #"{"code":40002,"msg":"动态票据来源不匹配"}"#)
            }
            if source == 1 {
                return .json(200, #"{"code":0,"msg":"课堂级签到成功"}"#)
            }
            return .json(404, #"{"code":40400}"#)
        }

        let res2 = await orchestrator2.checkIn(account: makeAccount(), ticket: ticket)
        XCTAssertEqual(res2.state, .success)
        XCTAssertEqual(res2.strategyId, "LESSON_DESKTOP")
        XCTAssertEqual(seenSourcesSecond.get(), [14, 5, 1])
        XCTAssertEqual(res2.attempts.map(\.strategyId), ["DYN_TICKET_14", "DYN_TICKET_5", "LESSON_DESKTOP"])
    }

    // MARK: - ALREADY / AUTH_EXPIRED / QR_EXPIRED Classification

    func testAlreadyDetectionAndPrecedenceOverSuccessAndUnder401() async throws {
        let profile = try TestBundleResources.loadProtocolProfile()
        let ticket = QrCodeParser.parse("lessonId=1001", profile: profile)

        let alreadyOrch = makeOrchestrator(profile: profile) { _ in
            .json(200, #"{"code":0,"msg":"已签到","data":{"signed":true}}"#)
        }
        let rAlready = await alreadyOrch.checkIn(account: makeAccount(), ticket: ticket)
        XCTAssertEqual(rAlready.state, .already)
        XCTAssertTrue(rAlready.state.isSuccessLike)

        let successOrch = makeOrchestrator(profile: profile) { _ in
            .json(200, #"{"code":0,"msg":"签到成功","data":{"signed":true}}"#)
        }
        let rSuccess = await successOrch.checkIn(account: makeAccount(), ticket: ticket)
        XCTAssertEqual(rSuccess.state, .success)
        XCTAssertTrue(rSuccess.state.isSuccessLike)

        let plainAlreadyOrch = makeOrchestrator(profile: profile) { _ in
            .text(200, "您已签到，无需重复提交")
        }
        let rPlainAlready = await plainAlreadyOrch.checkIn(account: makeAccount(), ticket: ticket)
        XCTAssertEqual(rPlainAlready.state, .already)

        let auth401Orch = makeOrchestrator(profile: profile) { _ in
            .text(401, "未登录：已签到状态不可查")
        }
        let r401 = await auth401Orch.checkIn(account: makeAccount(), ticket: ticket)
        XCTAssertEqual(r401.state, .authExpired)
    }

    func testAuthExpiredQrExpiredShortCircuitAndNetworkErrorIsolation() async throws {
        let profile = try TestBundleResources.loadProtocolProfile()
        let dynTicket = QrCodeParser.parse("c=abc&t=1763900000&s=sig&lessonId=1", profile: profile)

        // 1) HTTP 200 业务鉴权失败 -> AUTH_EXPIRED 且立即中止策略链
        let authCalls = LockedBox(0)
        let authOrch = makeOrchestrator(profile: profile) { _ in
            authCalls.withLock { $0 += 1 }
            return .json(200, #"{"code":40100,"msg":"Invalid TOKEN, please re-login"}"#)
        }
        let rAuth = await authOrch.checkIn(account: makeAccount(), ticket: dynTicket)
        XCTAssertEqual(rAuth.state, .authExpired)
        XCTAssertEqual(authCalls.get(), 1, "命中 AUTH_EXPIRED 必须立即中止后续策略")

        // 2) HTTP 500 含二维码过期关键词 -> QR_EXPIRED 且立即中止重试与策略链
        let expiredCalls = LockedBox(0)
        let expiredOrch = makeOrchestrator(profile: profile, maxAttemptsPerStrategy: 3, baseBackoffMs: 0) { _ in
            expiredCalls.withLock { $0 += 1 }
            return .json(500, #"{"code":50001,"msg":"二维码已失效"}"#)
        }
        let rExpired = await expiredOrch.checkIn(account: makeAccount(), ticket: dynTicket)
        XCTAssertEqual(rExpired.state, .qrExpired)
        XCTAssertEqual(expiredCalls.get(), 1, "即使 HTTP 500，命中 expiredKeywords 也必须立即中止重试与策略链")

        // 3) 传输层网络异常文本含 "token" 时，必须判 NETWORK_ERROR 而非 AUTH_EXPIRED
        let netOrch = makeOrchestrator(profile: profile, maxAttemptsPerStrategy: 2, baseBackoffMs: 0) { _ in
            throw NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorNetworkConnectionLost,
                userInfo: [NSLocalizedDescriptionKey: "Connection reset while checking token"]
            )
        }
        let rNet = await netOrch.checkIn(account: makeAccount(), ticket: QrCodeParser.parse("lessonId=1", profile: profile))
        XCTAssertEqual(rNet.state, .networkError)
    }

    // MARK: - Malicious URL Blocking on QR_URL_POST / QR_URL_GET

    func testMaliciousExternalUrlBlockedOnQrUrlPostAndGet() async throws {
        let profile = try TestBundleResources.loadProtocolProfile()
        let evilCalls = LockedBox(0)

        let orchestrator = makeOrchestrator(profile: profile) { request in
            if request.url?.host?.lowercased() == "evil.example" {
                evilCalls.withLock { $0 += 1 }
                return .json(
                    200,
                    #"{"code":0,"msg":"stolen"}"#,
                    headers: ["set-auth": "Bearer poisoned-token"]
                )
            }
            return .json(200, #"{"code":40002,"msg":"策略不匹配"}"#)
        }

        let maliciousTicket = QrCodeParser.parse(
            "https://evil.example/steal?c=bad&t=1763900000&s=sig&lessonId=1001",
            profile: profile
        )
        let result = await orchestrator.checkIn(account: makeAccount(), ticket: maliciousTicket)

        XCTAssertEqual(evilCalls.get(), 0, "绝不允许向恶意第三方域名发起任何网络请求")
        XCTAssertNil(result.refreshedAccount, "绝不允许吸收第三方响应头")
        XCTAssertEqual(result.state, .failed)
        XCTAssertTrue(
            result.attempts.contains { $0.strategyId == "QR_URL_POST" && $0.httpStatus == nil && $0.message.contains("安全拦截") },
            "QR_URL_POST 必须记录安全拦截轨迹"
        )
        XCTAssertTrue(
            result.attempts.contains { $0.strategyId == "QR_URL_GET" && $0.httpStatus == nil && $0.message.contains("安全拦截") },
            "QR_URL_GET 必须记录安全拦截轨迹"
        )

        // 禁止 HTTPS 账号被二维码降级为明文 HTTP
        let httpCalls = LockedBox(0)
        let downgradeOrch = makeOrchestrator(profile: profile) { request in
            if request.url?.scheme?.lowercased() == "http" {
                httpCalls.withLock { $0 += 1 }
            }
            return .json(200, #"{"code":40002,"msg":"策略不匹配"}"#)
        }
        let downgradeTicket = QrCodeParser.parse(
            "http://www.yuketang.cn/api/v3/lesson/checkin?c=abc&t=1&s=sig&lessonId=1",
            profile: profile
        )
        let downgradeRes = await downgradeOrch.checkIn(account: makeAccount(), ticket: downgradeTicket)
        XCTAssertEqual(httpCalls.get(), 0, "禁止向 HTTPS 站点降级发送明文 HTTP 请求")
        XCTAssertTrue(downgradeRes.attempts.contains { $0.strategyId == "QR_URL_POST" && $0.message.contains("安全拦截") })

        // 合法同源 QR_URL_POST（缺失 lessonId 且 activeLesson 为空）允许放行并成功
        let customPaths = LockedBox<[String]>([])
        let allowedOrch = makeOrchestrator(profile: profile) { request in
            let line = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
            customPaths.withLock { $0.append(line) }
            if request.url?.path == "/api/v3/classroom/on-lesson-upcoming-exam" {
                return .json(200, #"{"code":0,"data":{"onLessonClassrooms":[]}}"#)
            }
            if request.url?.path == "/api/v3/custom/qr-checkin" {
                return .json(200, #"{"code":0,"msg":"签到成功"}"#)
            }
            return .json(404, #"{"code":40400}"#)
        }
        let sameOriginTicket = QrCodeParser.parse(
            "https://www.yuketang.cn/api/v3/custom/qr-checkin?c=abc&t=1&s=sig",
            profile: profile
        )
        let sameOriginRes = await allowedOrch.checkIn(account: makeAccount(), ticket: sameOriginTicket)
        XCTAssertEqual(sameOriginRes.state, .success)
        XCTAssertEqual(sameOriginRes.strategyId, "QR_URL_POST")
        XCTAssertTrue(customPaths.get().contains("POST /api/v3/custom/qr-checkin"))
    }

    // MARK: - Strict Zero-Request Dry Run

    func testDryRunSendsZeroNetworkRequestsEvenWithoutLessonId() async throws {
        let profile = try TestBundleResources.loadProtocolProfile()
        let requestCount = LockedBox(0)

        let orchestrator = makeOrchestrator(profile: profile) { _ in
            requestCount.withLock { $0 += 1 }
            return .json(200, #"{"code":0,"msg":"不应被调用"}"#)
        }

        // 无 lessonId 的动态码在实网模式会触发 discoverActiveLesson；演练模式必须跳过且零请求
        let ticket = QrCodeParser.parse("c=dry01&t=1763900000&s=drysig&v=2", profile: profile)
        let batchResults = await orchestrator.checkInBatch(
            accounts: [makeAccount()],
            ticket: ticket,
            dryRun: true
        )

        XCTAssertEqual(requestCount.get(), 0, "dryRun 必须绝对零网络请求（包含跳过 activeLesson）")
        XCTAssertEqual(batchResults.count, 1)
        let single = try XCTUnwrap(batchResults.first)
        XCTAssertEqual(single.state, .dryRun)
        XCTAssertFalse(single.state.isSuccessLike, "演练模式 .dryRun 不应计入真实签到成功")
        XCTAssertTrue(single.state.isDryRun)
        XCTAssertFalse(single.state.isFailureLike, "演练模式 .dryRun 不应计入失败或可重试项")
        XCTAssertFalse(single.attempts.isEmpty)
        XCTAssertTrue(single.attempts.allSatisfy { $0.httpStatus == nil })
    }

    // MARK: - CFBoolean JSON Trap + errcode/errmsg + Credential Rotation

    func testCFBooleanJsonTrapSafetyAndErrcodeErrmsgFallback() async throws {
        let profile = try TestBundleResources.loadProtocolProfile()

        // 1) 底层解析：CFBoolean false/true 绝不桥接为 Int 0/1，NSNull 绝不变为字符串
        let rawPayload = Data(#"{"code":false,"errcode":true,"realCode":0,"msg":null,"errmsg":"ok"}"#.utf8)
        let parsed = try XCTUnwrap(RainCheckClient.parseJSONObject(from: rawPayload))
        XCTAssertEqual(parsed["code"], TemplateValue.bool(false))
        XCTAssertNil(parsed["code"]?.intValue, "CFBoolean false 绝不能误解析为业务码 0")
        XCTAssertEqual(parsed["errcode"], TemplateValue.bool(true))
        XCTAssertNil(parsed["errcode"]?.intValue, "CFBoolean true 绝不能误解析为业务码 1")
        XCTAssertEqual(parsed["realCode"]?.intValue, 0)
        XCTAssertNil(parsed["msg"]?.stringValue, "JSON null 不能污染消息文本")
        XCTAssertEqual(parsed["errmsg"]?.stringValue, "ok")

        // 2) 端到端验证：服务端返回 {"code":false,"msg":"未通过校验"} 绝不误判为 SUCCESS
        let boolTrapOrch = makeOrchestrator(profile: profile) { _ in
            .json(200, #"{"code":false,"msg":"未通过校验"}"#)
        }
        let boolTrapRes = await boolTrapOrch.checkIn(
            account: makeAccount(),
            ticket: QrCodeParser.parse("lessonId=10", profile: profile)
        )
        XCTAssertEqual(boolTrapRes.state, .failed)
        XCTAssertNotEqual(boolTrapRes.state, .success)

        // 3) 旧版 errcode / errmsg 兼容（已签到与成功）
        let legacyAlreadyOrch = makeOrchestrator(profile: profile) { _ in
            .json(200, #"{"errcode":0,"errmsg":"重复签到"}"#)
        }
        let rAlready = await legacyAlreadyOrch.checkIn(
            account: makeAccount(),
            ticket: QrCodeParser.parse("lessonId=10", profile: profile)
        )
        XCTAssertEqual(rAlready.state, .already)
        XCTAssertEqual(rAlready.message, "重复签到")

        let legacyOkOrch = makeOrchestrator(profile: profile) { _ in
            .json(200, #"{"errcode":0,"errmsg":"旧版接口签到成功"}"#)
        }
        let rOk = await legacyOkOrch.checkIn(
            account: makeAccount(),
            ticket: QrCodeParser.parse("lessonId=10", profile: profile)
        )
        XCTAssertEqual(rOk.state, .success)
        XCTAssertEqual(rOk.message, "旧版接口签到成功")
    }

    func testCredentialRotationPropagatesAcrossFallbackAndIgnoresExpiredCookies() async throws {
        let profile = try TestBundleResources.loadProtocolProfile()
        let seenAuthHeaders = LockedBox<[String?]>([])
        let seenCookies = LockedBox<[String?]>([])

        let orchestrator = makeOrchestrator(profile: profile) { request in
            seenAuthHeaders.withLock { $0.append(MockNetworkSupport.headerValue("Authorization", in: request)) }
            seenCookies.withLock { $0.append(MockNetworkSupport.headerValue("Cookie", in: request)) }
            let source = MockNetworkSupport.requestBodyJSON(from: request)?["source"]?.intValue
            if source == 14 {
                return .json(
                    200,
                    #"{"code":40002,"msg":"换小程序来源"}"#,
                    headers: [
                        "set-auth": "Bearer rotated-token-2",
                        "authorization": "Bearer lower-priority-token",
                        "Set-Cookie": "sessionid=sid-rotated-2; Path=/; HttpOnly"
                    ]
                )
            }
            return .json(
                200,
                #"{"code":0,"msg":"签到成功"}"#,
                headers: [
                    "Set-Cookie": "sessionid=; Max-Age=0; Path=/"
                ]
            )
        }

        let ticket = QrCodeParser.parse("c=abc&t=1&s=sig&lessonId=42", profile: profile)
        let result = await orchestrator.checkIn(
            account: makeAccount(bearer: "token-initial-1", sessionId: "keep-sid", csrfToken: "keep-csrf"),
            ticket: ticket
        )

        XCTAssertEqual(result.state, .success)
        XCTAssertEqual(result.strategyId, "DYN_TICKET_5")
        XCTAssertEqual(seenAuthHeaders.get(), ["Bearer token-initial-1", "Bearer rotated-token-2"])
        let secondCookieHeader = seenCookies.get().last.flatMap { $0 }
        XCTAssertTrue(secondCookieHeader?.contains("sessionid=sid-rotated-2") == true)
        XCTAssertEqual(result.refreshedAccount?.bearer, "rotated-token-2", "set-auth 优先级必须高于 authorization")
        XCTAssertEqual(result.refreshedAccount?.sessionId, "sid-rotated-2", "Max-Age=0 空 Cookie 不得清空有效 sessionId")
        XCTAssertEqual(result.refreshedAccount?.csrfToken, "keep-csrf")
    }

    func testCheckInBatchPreservesOrderAndSkipsDisabledAccounts() async throws {
        let profile = try TestBundleResources.loadProtocolProfile()
        let orchestrator = makeOrchestrator(profile: profile) { _ in
            .json(200, #"{"code":0,"msg":"签到成功"}"#)
        }

        let accounts = [
            makeAccount(id: "a1", label: "账号1", enabled: true),
            makeAccount(id: "a-disabled", label: "停用账号", enabled: false),
            makeAccount(id: "a2", label: "账号2", enabled: true),
            makeAccount(id: "a3", label: "账号3", enabled: true)
        ]
        let progressIds = LockedBox<[String]>([])
        let results = await orchestrator.checkInBatch(
            accounts: accounts,
            ticket: QrCodeParser.parse("lessonId=88", profile: profile),
            dryRun: false,
            maxConcurrency: 2,
            onProgress: { partial in
                progressIds.withLock { $0.append(partial.accountId) }
            }
        )

        XCTAssertEqual(results.map(\.accountId), ["a1", "a2", "a3"])
        XCTAssertEqual(Set(progressIds.get()), Set(["a1", "a2", "a3"]))
        XCTAssertTrue(results.allSatisfy { $0.state == .success })
    }

    // MARK: - SignResult Sanitized JSON Encoding

    func testSignResultJsonEncodingStrictlyExcludesSecrets() throws {
        let secretBearer = "SECRET_BEARER_DO_NOT_LEAK_999"
        let secretSession = "SECRET_SESSION_DO_NOT_LEAK_888"
        let secretCsrf = "SECRET_CSRF_DO_NOT_LEAK_777"

        let refreshed = Account(
            id: "acc-secret",
            label: "安全测试账号",
            host: "www.yuketang.cn",
            scheme: "https",
            bearer: secretBearer,
            sessionId: secretSession,
            csrfToken: secretCsrf
        )
        let original = SignResult(
            accountId: "acc-secret",
            accountLabel: "安全测试账号",
            host: "www.yuketang.cn",
            state: .success,
            strategyId: "DYN_TICKET_14",
            httpStatus: 200,
            message: "签到成功",
            elapsedMs: 42,
            attempts: [
                AttemptTrace(
                    strategyId: "DYN_TICKET_14",
                    method: "POST",
                    url: "https://www.yuketang.cn/api/v3/lesson/checkin",
                    httpStatus: 200,
                    businessCode: 0,
                    message: "签到成功",
                    elapsedMs: 42
                )
            ],
            timestampMs: 1_763_900_000_000,
            refreshedAccount: refreshed
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encodedData = try encoder.encode(original)
        let encodedText = try XCTUnwrap(String(data: encodedData, encoding: .utf8))

        for forbidden in ["refreshedAccount", "bearer", "sessionId", "csrfToken", secretBearer, secretSession, secretCsrf] {
            XCTAssertFalse(
                encodedText.contains(forbidden),
                "SignResult JSON 序列化绝对不能包含敏感字段或明文凭据: \(forbidden)"
            )
        }

        let decoded = try JSONDecoder().decode(SignResult.self, from: encodedData)
        XCTAssertNil(decoded.refreshedAccount)
        XCTAssertEqual(decoded.accountId, original.accountId)
        XCTAssertEqual(decoded.state, .success)
        XCTAssertEqual(decoded.strategyId, "DYN_TICKET_14")
        XCTAssertEqual(decoded.attempts.count, 1)
    }

    // MARK: - KeychainVault & AppStore Persistence & Sanitized Export

    func testKeychainVaultSeparatesSecretsFromMetadataAndExcludesBackup() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("raincheck-vault-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let metadataURL = tempDir.appendingPathComponent("accounts_metadata.json")
        let secretStore = InMemorySecretStorage()
        let vault = KeychainVault(
            service: "cn.raincheck.ios.tests.\(UUID().uuidString)",
            metadataURL: metadataURL,
            secretStorage: secretStore
        )

        let acc1 = Account(
            id: "v-1",
            label: "一号账号",
            host: "www.yuketang.cn",
            scheme: "https",
            bearer: "VAULT_BEARER_SECRET_1",
            sessionId: "VAULT_SID_SECRET_1",
            csrfToken: "VAULT_CSRF_SECRET_1",
            note: "早八高数"
        )
        let acc2 = Account(
            id: "v-2",
            label: "二号账号",
            host: "pro.yuketang.cn",
            scheme: "https",
            bearer: "VAULT_BEARER_SECRET_2"
        )

        try vault.save([acc1, acc2])

        // 元数据 JSON 存在、标记不备份、且绝不含任何明文凭据
        let diskText = try String(contentsOf: metadataURL, encoding: .utf8)
        XCTAssertTrue(diskText.contains("一号账号"))
        XCTAssertTrue(diskText.contains("早八高数"))
        for forbidden in [
            "bearer", "sessionId", "csrfToken",
            "VAULT_BEARER_SECRET_1", "VAULT_SID_SECRET_1", "VAULT_CSRF_SECRET_1", "VAULT_BEARER_SECRET_2"
        ] {
            XCTAssertFalse(diskText.contains(forbidden), "磁盘元数据文件不得包含凭据字段或明文: \(forbidden)")
        }

        let freshMetadataURL = URL(fileURLWithPath: metadataURL.path)
        let resourceValues = try freshMetadataURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(resourceValues.isExcludedFromBackup, true)
        XCTAssertEqual(secretStore.storedAccountIds(), Set(["v-1", "v-2"]))

        // 通过新 Vault 实例重新加载，验证完整合并还原
        let reloadedVault = KeychainVault(
            service: vault.service,
            metadataURL: metadataURL,
            secretStorage: secretStore
        )
        let reloaded = reloadedVault.load()
        XCTAssertEqual(reloaded.count, 2)
        let r1 = try XCTUnwrap(reloaded.first(where: { $0.id == "v-1" }))
        XCTAssertEqual(r1.bearer, "VAULT_BEARER_SECRET_1")
        XCTAssertEqual(r1.sessionId, "VAULT_SID_SECRET_1")
        XCTAssertEqual(r1.csrfToken, "VAULT_CSRF_SECRET_1")
        XCTAssertEqual(r1.note, "早八高数")

        // 删除账号同步清理凭据；清空凭据删除对应密钥项
        try vault.remove(id: "v-1")
        XCTAssertEqual(vault.load().map(\.id), ["v-2"])
        XCTAssertEqual(secretStore.storedAccountIds(), Set(["v-2"]))

        var clearedAcc2 = acc2
        clearedAcc2.bearer = nil
        try vault.upsert(clearedAcc2)
        XCTAssertTrue(secretStore.storedAccountIds().isEmpty)
    }

    @MainActor
    func testAppStorePersistenceNoAutoSignOnScanAndSanitizedExport() async throws {
        let profile = try TestBundleResources.loadProtocolProfile()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("raincheck-store-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let metadataURL = tempDir.appendingPathComponent("accounts_metadata.json")
        let secretStore = InMemorySecretStorage()
        let vault = KeychainVault(
            service: "cn.raincheck.ios.storetests.\(UUID().uuidString)",
            metadataURL: metadataURL,
            secretStorage: secretStore
        )

        let originalToken = "STORE_ORIG_SECRET_TOKEN_111"
        let rotatedToken = "STORE_ROTATED_SECRET_TOKEN_222"
        let networkCalls = LockedBox(0)

        let session = MockNetworkSupport.makeSession { _ in
            networkCalls.withLock { $0 += 1 }
            return .json(
                200,
                #"{"code":0,"msg":"签到成功"}"#,
                headers: ["set-auth": "Bearer \(rotatedToken)"]
            )
        }

        let store = AppStore(vault: vault, profile: profile, session: session)
        let account = makeAccount(
            id: "store-acc-1",
            label: "林同学",
            bearer: originalToken,
            sessionId: "STORE_SID_SECRET_333",
            csrfToken: "STORE_CSRF_SECRET_444"
        )
        try store.addOrUpdateAccount(account)

        XCTAssertEqual(store.accounts.count, 1)
        XCTAssertTrue(store.selectedAccountIds.contains("store-acc-1"))
        XCTAssertEqual(vault.load().first?.bearer, originalToken)

        // 扫描/粘贴二维码绝不自动触发签到网络请求
        store.applyQrInput("https://evil.example/steal?c=x&t=1&s=2")
        XCTAssertFalse(store.isCurrentTicketHostTrusted())
        XCTAssertEqual(networkCalls.get(), 0)

        store.applyQrInput("https://www.yuketang.cn/api/v3/lesson/checkin?c=ok1&t=1763900000&s=sig1&lessonId=7788")
        XCTAssertEqual(store.currentTicket?.kind, TicketKind.dynamicCheckin)
        XCTAssertTrue(store.isCurrentTicketHostTrusted())
        XCTAssertFalse(store.isCheckingIn)
        XCTAssertEqual(networkCalls.get(), 0, "applyQrInput 绝不能在用户显式确认前自动发起签到")

        // 用户显式触发签到，等待完成并验证凭据安全回填与脱敏导出
        store.startCheckIn()
        var waitTicks = 0
        while store.isCheckingIn && waitTicks < 100 {
            waitTicks += 1
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertFalse(store.isCheckingIn)
        XCTAssertEqual(networkCalls.get(), 1)
        XCTAssertEqual(store.results.count, 1)
        XCTAssertEqual(store.results.first?.state, SignState.success)
        XCTAssertEqual(store.accounts.first?.bearer, rotatedToken, "轮换后的新凭据应安全回填到账号池")
        XCTAssertEqual(vault.load().first?.bearer, rotatedToken, "轮换后的新凭据应同步持久化到 Vault")

        let reportData = try store.exportSanitizedReportData()
        let reportText = try XCTUnwrap(String(data: reportData, encoding: .utf8))
        XCTAssertTrue(reportText.contains("林同学"))
        XCTAssertTrue(reportText.contains("SUCCESS"))
        for forbidden in [
            "refreshedAccount", "bearer", "sessionId", "csrfToken",
            originalToken, rotatedToken, "STORE_SID_SECRET_333", "STORE_CSRF_SECRET_444"
        ] {
            XCTAssertFalse(reportText.contains(forbidden), "导出报告不得包含敏感字段或凭据: \(forbidden)")
        }

        let reportURL = try store.exportSanitizedReportURL()
        defer { try? FileManager.default.removeItem(at: reportURL) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: reportURL.path))
    }

    // MARK: - Cookie-Only Web Headers & Auth-Expired Classification Hardening

    func testCookieOnlyCheckInSendsCleanWebHeadersAcrossEditionsAndEndpoints() async throws {
        struct CapturedCheckInRequest: Sendable {
            let path: String
            let xClient: String?
            let xtbz: String?
            let origin: String?
            let referer: String?
            let desktopV: String?
            let authorization: String?
            let cookie: String?
            let csrfHeader: String?
        }

        let profile = try TestBundleResources.loadProtocolProfile()

        // 验证协议配置与内置兜底均已切换为纯 Web 请求头
        XCTAssertEqual(profile.headers["X-Client"], "web")
        XCTAssertEqual(profile.headers["xtbz"], "ykt")
        XCTAssertNil(profile.headers["desktop-v"])
        XCTAssertNil(profile.headers["Origin"])
        XCTAssertEqual(ProtocolCatalog.fallback.headers["X-Client"], "web")
        XCTAssertEqual(ProtocolCatalog.fallback.headers["xtbz"], "ykt")
        XCTAssertNil(ProtocolCatalog.fallback.headers["desktop-v"])
        XCTAssertNil(ProtocolCatalog.fallback.headers["Origin"])

        let editionIds = ["www", "pro", "changjiang", "huanghe", "mock"]
        for editionId in editionIds {
            let edition = try XCTUnwrap(profile.edition(editionId), "profile 应包含站点 \(editionId)")
            let expectedOrigin = "\(edition.scheme)://\(edition.host)"
            let captured = LockedBox<[CapturedCheckInRequest]>([])

            let orchestrator = makeOrchestrator(profile: profile) { request in
                let path = request.url?.path ?? ""
                captured.withLock {
                    $0.append(
                        CapturedCheckInRequest(
                            path: path,
                            xClient: MockNetworkSupport.headerValue("X-Client", in: request),
                            xtbz: MockNetworkSupport.headerValue("xtbz", in: request),
                            origin: MockNetworkSupport.headerValue("Origin", in: request),
                            referer: MockNetworkSupport.headerValue("Referer", in: request),
                            desktopV: MockNetworkSupport.headerValue("desktop-v", in: request),
                            authorization: MockNetworkSupport.headerValue("Authorization", in: request),
                            cookie: MockNetworkSupport.headerValue("Cookie", in: request),
                            csrfHeader: MockNetworkSupport.headerValue("X-CSRFToken", in: request)
                        )
                    )
                }

                if path == "/api/v3/classroom/on-lesson-upcoming-exam" {
                    return .json(
                        200,
                        #"{"code":0,"msg":"","data":{"onLessonClassrooms":[{"lessonId":"555","classroomId":"666","courseName":"高等数学"}]}}"#
                    )
                }
                if path == "/api/v3/lesson/checkin" {
                    let source = MockNetworkSupport.requestBodyJSON(from: request)?["source"]?.intValue
                    if source == 14 || source == 5 {
                        return .json(200, #"{"code":40002,"msg":"尝试课堂级签到"}"#)
                    }
                    if source == 1 {
                        return .json(200, #"{"code":0,"msg":"签到成功"}"#)
                    }
                }
                return .json(404, #"{"code":40400}"#)
            }

            let cookieOnlyAccount = makeAccount(
                id: "cookie-acc-\(editionId)",
                label: "纯Cookie用户",
                host: edition.host,
                scheme: edition.scheme,
                bearer: nil,
                sessionId: "web-sid-\(editionId)",
                csrfToken: "web-csrf-\(editionId)"
            )
            // 无 lessonId 动态码：覆盖 activeLesson -> checkinTicket(14) -> checkinTicket(5) -> checkinDesktop(1)
            let ticket = QrCodeParser.parse("c=webcode1&t=1763900000&s=websig1&v=2", profile: profile)
            let result = await orchestrator.checkIn(account: cookieOnlyAccount, ticket: ticket)

            XCTAssertEqual(result.state, .success, "\(editionId) 纯 Cookie 签到应成功")
            XCTAssertEqual(result.strategyId, "LESSON_DESKTOP")

            let requests = captured.get()
            XCTAssertEqual(requests.count, 4, "\(editionId) 应覆盖 activeLesson + DYN_TICKET_14 + DYN_TICKET_5 + LESSON_DESKTOP")
            for req in requests {
                XCTAssertEqual(req.xClient, "web", "\(editionId) \(req.path) 必须发送 X-Client: web")
                XCTAssertEqual(req.xtbz, "ykt", "\(editionId) \(req.path) 必须发送 xtbz: ykt")
                XCTAssertEqual(req.origin, expectedOrigin, "\(editionId) \(req.path) Origin 必须同源")
                XCTAssertNotEqual(req.origin, "file://", "\(editionId) \(req.path) 绝不可发送 Origin: file://")
                XCTAssertNil(req.desktopV, "\(editionId) \(req.path) 绝不可发送 desktop-v")
                XCTAssertNil(req.authorization, "\(editionId) \(req.path) 纯 Cookie 账号不应发送 Authorization")
                XCTAssertTrue(req.cookie?.contains("sessionid=web-sid-\(editionId)") == true)
                XCTAssertTrue(req.cookie?.contains("csrftoken=web-csrf-\(editionId)") == true)
                XCTAssertEqual(req.csrfHeader, "web-csrf-\(editionId)")

                if req.path == "/api/v3/classroom/on-lesson-upcoming-exam" {
                    XCTAssertEqual(req.referer, "\(expectedOrigin)/v2/web/index")
                } else {
                    XCTAssertEqual(req.referer, "\(expectedOrigin)/v2/web/studentLog/666")
                }
                XCTAssertTrue(req.referer?.hasPrefix("\(expectedOrigin)/v2/web/") == true)
            }
        }

        // 覆盖 LESSON_WEB (/api/lesson/web_check_in) 纯 Cookie 请求头
        let webFallbackCaptured = LockedBox<[CapturedCheckInRequest]>([])
        let webOrch = makeOrchestrator(profile: profile) { request in
            let path = request.url?.path ?? ""
            webFallbackCaptured.withLock {
                $0.append(
                    CapturedCheckInRequest(
                        path: path,
                        xClient: MockNetworkSupport.headerValue("X-Client", in: request),
                        xtbz: MockNetworkSupport.headerValue("xtbz", in: request),
                        origin: MockNetworkSupport.headerValue("Origin", in: request),
                        referer: MockNetworkSupport.headerValue("Referer", in: request),
                        desktopV: MockNetworkSupport.headerValue("desktop-v", in: request),
                        authorization: MockNetworkSupport.headerValue("Authorization", in: request),
                        cookie: MockNetworkSupport.headerValue("Cookie", in: request),
                        csrfHeader: MockNetworkSupport.headerValue("X-CSRFToken", in: request)
                    )
                )
            }
            if path == "/api/v3/lesson/checkin" {
                return .json(200, #"{"code":40002,"msg":"改走网页端签到"}"#)
            }
            if path == "/api/lesson/web_check_in" {
                return .json(200, #"{"code":0,"msg":"网页端签到成功"}"#)
            }
            return .json(404, #"{"code":40400}"#)
        }
        let wwwCookieAccount = makeAccount(
            id: "cookie-acc-web",
            label: "网页兜底测试",
            host: "www.yuketang.cn",
            scheme: "https",
            bearer: nil,
            sessionId: "web-sid-fallback",
            csrfToken: "web-csrf-fallback"
        )
        let webRes = await webOrch.checkIn(
            account: wwwCookieAccount,
            ticket: QrCodeParser.parse("lessonId=777", profile: profile)
        )
        XCTAssertEqual(webRes.state, .success)
        XCTAssertEqual(webRes.strategyId, "LESSON_WEB")

        let webReq = try XCTUnwrap(webFallbackCaptured.get().last)
        XCTAssertEqual(webReq.path, "/api/lesson/web_check_in")
        XCTAssertEqual(webReq.xClient, "web")
        XCTAssertEqual(webReq.xtbz, "ykt")
        XCTAssertEqual(webReq.origin, "https://www.yuketang.cn")
        XCTAssertNotEqual(webReq.origin, "file://")
        XCTAssertEqual(webReq.referer, "https://www.yuketang.cn/v2/web/index")
        XCTAssertNil(webReq.desktopV)
        XCTAssertNil(webReq.authorization)
        XCTAssertTrue(webReq.cookie?.contains("sessionid=web-sid-fallback") == true)
    }

    func testCode50000UnauthenticatedAndTypoLoginFailureClassifyAsAuthExpired() async throws {
        let profile = try TestBundleResources.loadProtocolProfile()
        XCTAssertTrue(profile.result.authKeywords.contains("unauthenticated"))
        XCTAssertTrue(profile.result.authKeywords.contains("登陆"))
        XCTAssertTrue(ProtocolCatalog.fallback.result.authKeywords.contains("unauthenticated"))
        XCTAssertTrue(ProtocolCatalog.fallback.result.authKeywords.contains("登陆"))

        let dynTicket = QrCodeParser.parse("c=auth1&t=1763900000&s=sig1&lessonId=2026", profile: profile)
        let noLessonTicket = QrCodeParser.parse("c=auth2&t=1763900000&s=sig2", profile: profile)

        // 1) 直接分类校验：code 50000 UNAUTHENTICATED 与“登陆失败，请重新登录”/“登陆失败，请重试”
        let classifier = makeOrchestrator(profile: profile) { _ in .json(200, #"{"code":0}"#) }
        XCTAssertEqual(
            classifier.classify(httpStatus: 200, businessCode: 50000, message: "UNAUTHENTICATED", bodyText: ""),
            .authExpired
        )
        XCTAssertEqual(
            classifier.classify(httpStatus: 200, businessCode: 401, message: "登陆失败，请重新登录", bodyText: ""),
            .authExpired
        )
        XCTAssertEqual(
            classifier.classify(httpStatus: 200, businessCode: 40100, message: "登陆失败，请重试", bodyText: ""),
            .authExpired
        )

        // 2) 端到端签到：HTTP 200 {"code":50000,"msg":"UNAUTHENTICATED","data":""} -> .authExpired 且立即中止策略链
        let unauthCalls = LockedBox(0)
        let unauthOrch = makeOrchestrator(profile: profile) { _ in
            unauthCalls.withLock { $0 += 1 }
            return .json(200, #"{"code":50000,"msg":"UNAUTHENTICATED","data":""}"#)
        }
        let rUnauth = await unauthOrch.checkIn(
            account: makeAccount(bearer: nil, sessionId: "expired-sid"),
            ticket: dynTicket
        )
        XCTAssertEqual(rUnauth.state, .authExpired)
        XCTAssertEqual(unauthCalls.get(), 1, "code 50000 UNAUTHENTICATED 必须归类为 .authExpired 并立即中止")

        // 3) 端到端 activeLesson 发现阶段返回 50000 UNAUTHENTICATED -> .authExpired
        let discoverCalls = LockedBox(0)
        let discoverOrch = makeOrchestrator(profile: profile) { _ in
            discoverCalls.withLock { $0 += 1 }
            return .json(200, #"{"code":50000,"msg":"UNAUTHENTICATED","data":""}"#)
        }
        let rDiscover = await discoverOrch.checkIn(
            account: makeAccount(bearer: nil, sessionId: "expired-sid"),
            ticket: noLessonTicket
        )
        XCTAssertEqual(rDiscover.state, .authExpired)
        XCTAssertEqual(discoverCalls.get(), 1)

        // 4) 端到端签到：HTTP 200 {"code":401,"msg":"登陆失败，请重新登录"} -> .authExpired 且立即中止
        let typoCalls = LockedBox(0)
        let typoOrch = makeOrchestrator(profile: profile) { _ in
            typoCalls.withLock { $0 += 1 }
            return .json(200, #"{"code":401,"msg":"登陆失败，请重新登录"}"#)
        }
        let rTypo = await typoOrch.checkIn(
            account: makeAccount(bearer: nil, sessionId: "expired-sid"),
            ticket: dynTicket
        )
        XCTAssertEqual(rTypo.state, .authExpired)
        XCTAssertEqual(typoCalls.get(), 1, "“登陆失败，请重新登录”必须归类为 .authExpired 并立即中止")

        // 5) 仅含“登陆”异体字（不含“登录”）也必须归类为 .authExpired
        let typoOnlyCalls = LockedBox(0)
        let typoOnlyOrch = makeOrchestrator(profile: profile) { _ in
            typoOnlyCalls.withLock { $0 += 1 }
            return .json(200, #"{"code":40100,"msg":"登陆失败，请重试"}"#)
        }
        let rTypoOnly = await typoOnlyOrch.checkIn(
            account: makeAccount(bearer: nil, sessionId: "expired-sid"),
            ticket: dynTicket
        )
        XCTAssertEqual(rTypoOnly.state, .authExpired)
        XCTAssertEqual(typoOnlyCalls.get(), 1)
    }

    // MARK: - B2 Stale-Bearer Fallback & businessCode == 401

    @MainActor
    func testStaleBearerFallsBackToCookieOnlyInDiscoverActiveLessonAndClearsVault() async throws {
        struct RecordedReq: Sendable {
            let path: String
            let auth: String?
            let cookie: String?
        }

        let profile = try TestBundleResources.loadProtocolProfile()
        let vault = InMemoryAccountVault()
        let recorded = LockedBox<[RecordedReq]>([])

        let session = MockNetworkSupport.makeSession { request in
            let path = request.url?.path ?? ""
            let auth = MockNetworkSupport.headerValue("Authorization", in: request)
            let cookie = MockNetworkSupport.headerValue("Cookie", in: request)
            recorded.withLock { $0.append(RecordedReq(path: path, auth: auth, cookie: cookie)) }

            if auth != nil {
                return .json(401, #"{"code":401,"msg":"登录已过期"}"#)
            }
            if path == "/api/v3/classroom/on-lesson-upcoming-exam" {
                return .json(
                    200,
                    #"{"code":0,"msg":"","data":{"onLessonClassrooms":[{"lessonId":"9001","classroomId":"7001","courseName":"数据结构"}]}}"#
                )
            }
            if path == "/api/v3/lesson/checkin" {
                return .json(200, #"{"code":0,"msg":"签到成功"}"#)
            }
            return .json(404, #"{"code":40400}"#)
        }

        let store = AppStore(vault: vault, profile: profile, session: session)
        let staleAcc = makeAccount(
            id: "acc-stale-discover",
            label: "陈同学",
            bearer: "stale-short-jwt-1",
            sessionId: "valid-web-sid-1",
            csrfToken: "valid-web-csrf-1"
        )
        try store.addOrUpdateAccount(staleAcc)

        // 无 lessonId 的动态码 -> 先触发 discoverActiveLesson（401 -> 纯 Cookie 重试 200 -> 后续 checkin 直接纯 Cookie）
        store.applyQrInput("c=dyn1&t=1763900000&s=sig1")
        store.startCheckIn()

        var ticks = 0
        while store.isCheckingIn && ticks < 100 {
            ticks += 1
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertFalse(store.isCheckingIn)
        let result = try XCTUnwrap(store.results.first)
        XCTAssertEqual(result.state, .success)
        XCTAssertEqual(result.attempts.filter { $0.strategyId == "DISCOVER_ACTIVE_LESSON" }.count, 2)

        let reqs = recorded.get()
        XCTAssertEqual(reqs.count, 3)
        XCTAssertEqual(reqs[0].path, "/api/v3/classroom/on-lesson-upcoming-exam")
        XCTAssertEqual(reqs[0].auth, "Bearer stale-short-jwt-1")
        XCTAssertEqual(reqs[1].path, "/api/v3/classroom/on-lesson-upcoming-exam")
        XCTAssertNil(reqs[1].auth, "activeLesson 纯 Cookie 回退不得携带过期 Authorization")
        XCTAssertTrue(reqs[1].cookie?.contains("sessionid=valid-web-sid-1") == true)
        XCTAssertEqual(reqs[2].path, "/api/v3/lesson/checkin")
        XCTAssertNil(reqs[2].auth, "清除过期 bearer 后后续 checkin 必须直接纯 Cookie 发送")

        let updatedAccount = try XCTUnwrap(store.accounts.first(where: { $0.id == "acc-stale-discover" }))
        XCTAssertNil(updatedAccount.bearer, "AppStore 应同步清空已过期的 bearer")
        XCTAssertEqual(updatedAccount.sessionId, "valid-web-sid-1")
        XCTAssertNil(vault.load().first?.bearer, "Vault 应持久化清空后的 bearer")
    }

    @MainActor
    func testStaleBearerFallsBackToCookieOnlyInExecuteStrategyAndHandlesBusinessCode401() async throws {
        let profile = try TestBundleResources.loadProtocolProfile()

        // 1) classify 与 discoverActiveLesson 均将 businessCode == 401（即使消息不含 authKeywords）判为 .authExpired
        let classifier = makeOrchestrator(profile: profile) { _ in
            .json(200, #"{"code":401,"msg":"expired"}"#)
        }
        XCTAssertEqual(
            classifier.classify(httpStatus: 200, businessCode: 401, message: "expired", bodyText: ""),
            .authExpired
        )
        XCTAssertEqual(
            classifier.classify(httpStatus: 200, businessCode: 401, message: nil, bodyText: #"{"code":401}"#),
            .authExpired
        )
        let discover401Res = await classifier.checkIn(
            account: makeAccount(bearer: nil, sessionId: "expired-only-sid"),
            ticket: QrCodeParser.parse("c=code401&t=1763900000&s=sig", profile: profile)
        )
        XCTAssertEqual(discover401Res.state, .authExpired)

        // 2) executeStrategy 命中 businessCode == 401 时，若同时持有 bearer 与 sessionId，单次回退纯 Cookie 并清除失效 bearer
        let vault = InMemoryAccountVault()
        let seenAuths = LockedBox<[String?]>([])
        let session = MockNetworkSupport.makeSession { request in
            let auth = MockNetworkSupport.headerValue("Authorization", in: request)
            seenAuths.withLock { $0.append(auth) }
            if auth != nil {
                return .json(200, #"{"code":401,"msg":"expired"}"#)
            }
            return .json(200, #"{"code":0,"msg":"签到成功"}"#)
        }

        let store = AppStore(vault: vault, profile: profile, session: session)
        let staleAcc = makeAccount(
            id: "acc-stale-strategy",
            label: "林同学",
            bearer: "stale-jwt-strategy",
            sessionId: "valid-sid-strategy",
            csrfToken: "valid-csrf-strategy"
        )
        try store.addOrUpdateAccount(staleAcc)

        store.applyQrInput("c=dyn2&t=1763900000&s=sig2&lessonId=8899")
        store.startCheckIn()

        var ticks = 0
        while store.isCheckingIn && ticks < 100 {
            ticks += 1
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertFalse(store.isCheckingIn)
        let result = try XCTUnwrap(store.results.first)
        XCTAssertEqual(result.state, .success)
        XCTAssertEqual(seenAuths.get(), ["Bearer stale-jwt-strategy", nil])
        XCTAssertEqual(result.attempts.count, 2)
        let refreshed = try XCTUnwrap(result.refreshedAccount, "纯 Cookie 回退成功后必须回传 refreshedAccount 以清理旧 bearer")
        XCTAssertNil(refreshed.bearer)
        XCTAssertEqual(refreshed.sessionId, "valid-sid-strategy")
        XCTAssertNil(store.accounts.first?.bearer)
        XCTAssertNil(vault.load().first?.bearer)
    }

    // MARK: - B5 Discover NetworkError Fallback, DryRun Separation & Retry Binding

    func testDiscoverSuccessFollowedByAllNetworkErrorsClassifiesAsNetworkError() async throws {
        let profile = try TestBundleResources.loadProtocolProfile()
        let orchestrator = makeOrchestrator(profile: profile, maxAttemptsPerStrategy: 1, baseBackoffMs: 0) { request in
            if request.url?.path == "/api/v3/classroom/on-lesson-upcoming-exam" {
                return .json(
                    200,
                    #"{"code":0,"msg":"","data":{"onLessonClassrooms":[{"lessonId":"555","classroomId":"666","courseName":"概率论"}]}}"#
                )
            }
            throw NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorNetworkConnectionLost,
                userInfo: [NSLocalizedDescriptionKey: "The network connection was lost."]
            )
        }

        // 无 lessonId 且 URL 为非白名单域名：activeLesson 成功 + 全部 HTTP 签到策略网络异常 + 尾部 QR_URL_* 本地安全拦截
        let ticket = QrCodeParser.parse(
            "https://evil.example/steal?c=netfail&t=1763900000&s=sig",
            profile: profile
        )
        let result = await orchestrator.checkIn(account: makeAccount(), ticket: ticket)

        XCTAssertEqual(result.state, .networkError, "排除 DISCOVER_ACTIVE_LESSON 后所有 HTTP 策略均为网络异常时应判为 .networkError")
        XCTAssertTrue(result.attempts.contains { $0.strategyId == "DISCOVER_ACTIVE_LESSON" && $0.httpStatus == 200 })
        XCTAssertTrue(result.attempts.contains { $0.strategyId == "QR_URL_POST" && $0.httpStatus == nil })
    }

    @MainActor
    func testAppStoreRetryFailedUsesLastBatchTicketAndForcesRealCheckIn() async throws {
        struct CapturedCall: Sendable {
            let auth: String
            let lessonId: String
        }

        XCTAssertFalse(SignState.dryRun.isSuccessLike)
        XCTAssertTrue(SignState.dryRun.isDryRun)
        XCTAssertFalse(SignState.dryRun.isFailureLike)
        XCTAssertTrue(SignState.success.isSuccessLike)
        XCTAssertTrue(SignState.already.isSuccessLike)
        XCTAssertFalse(SignState.success.isFailureLike)
        XCTAssertTrue(SignState.failed.isFailureLike)
        XCTAssertTrue(SignState.networkError.isFailureLike)

        let profile = try TestBundleResources.loadProtocolProfile()
        let vault = InMemoryAccountVault()
        let shouldFailAcc2 = LockedBox(true)
        let seenCalls = LockedBox<[CapturedCall]>([])

        let session = MockNetworkSupport.makeSession { request in
            let auth = MockNetworkSupport.headerValue("Authorization", in: request) ?? ""
            let body = MockNetworkSupport.requestBodyJSON(from: request)
            let lessonId = body?["lessonId"]?.stringValue ?? ""
            seenCalls.withLock { $0.append(CapturedCall(auth: auth, lessonId: lessonId)) }

            if auth == "Bearer tok-acc-2" && shouldFailAcc2.get() {
                return .json(200, #"{"code":40002,"msg":"临时失败"}"#)
            }
            return .json(200, #"{"code":0,"msg":"签到成功"}"#)
        }

        let store = AppStore(vault: vault, profile: profile, session: session)
        try store.addOrUpdateAccount(makeAccount(id: "acc-1", label: "账号1", bearer: "tok-acc-1"))
        try store.addOrUpdateAccount(makeAccount(id: "acc-2", label: "账号2", bearer: "tok-acc-2"))

        // 1) 使用 Ticket A (lessonId=1111) 执行真实签到：acc-1 成功，acc-2 失败
        store.applyQrInput("lessonId=1111")
        let ticketA = try XCTUnwrap(store.currentTicket)
        store.startCheckIn()

        var ticks = 0
        while store.isCheckingIn && ticks < 100 {
            ticks += 1
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(store.lastBatchTicket, ticketA)
        XCTAssertEqual(store.results.first(where: { $0.accountId == "acc-1" })?.state, .success)
        XCTAssertEqual(store.results.first(where: { $0.accountId == "acc-2" })?.state, .failed)

        // 2) 切换 currentTicket 为 Ticket B (lessonId=2222) 并打开 dryRun 开关
        store.applyQrInput("lessonId=2222")
        let ticketB = try XCTUnwrap(store.currentTicket)
        store.dryRun = true
        shouldFailAcc2.set(false)
        seenCalls.set([])

        // 3) retryFailed 必须使用 lastBatchTicket (1111) 且强制 dryRun=false 仅重试失败账号 acc-2
        store.retryFailed()
        ticks = 0
        while store.isCheckingIn && ticks < 100 {
            ticks += 1
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertFalse(store.isCheckingIn)
        XCTAssertEqual(store.currentTicket, ticketB, "retryFailed 不得覆盖 currentTicket")
        XCTAssertTrue(store.dryRun, "retryFailed 不得修改全局 dryRun 开关")
        XCTAssertEqual(store.results.first(where: { $0.accountId == "acc-2" })?.state, .success)
        let retryCalls = seenCalls.get()
        XCTAssertEqual(retryCalls.count, 1)
        XCTAssertEqual(retryCalls.first?.auth, "Bearer tok-acc-2")
        XCTAssertEqual(retryCalls.first?.lessonId, "1111", "retryFailed 必须绑定上一批次的 Ticket A (lessonId=1111)")

        // 4) 演练批次结果绝不被 retryFailed 当作失败项触发真实网络请求
        seenCalls.set([])
        store.startCheckIn() // dryRun == true
        ticks = 0
        while store.isCheckingIn && ticks < 100 {
            ticks += 1
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(store.results.allSatisfy { $0.state == .dryRun })
        store.retryFailed()
        XCTAssertFalse(store.isCheckingIn)
        XCTAssertTrue(seenCalls.get().isEmpty, "演练结果不应被 retryFailed 误判为失败项")
    }

    // MARK: - B6 Stagger Across Queued Batch Accounts

    func testCheckInBatchAppliesStaggerAcrossQueuedAccountsBeyondConcurrencyLimit() async throws {
        let profile = try TestBundleResources.loadProtocolProfile()
        let batchStartedMs = RainCheckTime.nowMillis()
        let orchestrator = makeOrchestrator(
            profile: profile,
            maxAttemptsPerStrategy: 1,
            baseBackoffMs: 0,
            staggerMs: 50
        ) { _ in
            .json(200, #"{"code":0,"msg":"签到成功"}"#)
        }

        let accounts = (0..<4).map { idx in
            makeAccount(id: "stagger-\(idx)", label: "账号\(idx)", bearer: "tok-\(idx)")
        }
        let results = await orchestrator.checkInBatch(
            accounts: accounts,
            ticket: QrCodeParser.parse("lessonId=3030", profile: profile),
            dryRun: false,
            maxConcurrency: 2
        )
        let elapsedMs = RainCheckTime.nowMillis() - batchStartedMs

        XCTAssertEqual(results.map(\.accountId), ["stagger-0", "stagger-1", "stagger-2", "stagger-3"])
        XCTAssertTrue(results.allSatisfy { $0.state == .success })
        // 4 个账号 staggerMs=50 -> 索引 3 目标延迟 150ms；留 50ms 调度余量断言 >= 100ms
        XCTAssertGreaterThanOrEqual(elapsedMs, 100, "超过并发上限的后续排队账号也应按索引应用 staggerMs 错峰延迟")
    }
}
