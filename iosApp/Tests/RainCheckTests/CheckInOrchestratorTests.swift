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
        let checkinCalls = LockedBox(0)

        let session = MockNetworkSupport.makeSession { request in
            networkCalls.withLock { $0 += 1 }
            let path = request.url?.path ?? ""
            if path == "/api/v3/app/scan" {
                return .json(
                    200,
                    #"{"code":0,"msg":"OK","data":{"type":"checkin","value":"1529274209982060032"}}"#
                )
            }
            checkinCalls.withLock { $0 += 1 }
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
        XCTAssertEqual(networkCalls.get(), 2, "官方两步扫码应执行 app/scan + lesson/checkin")
        XCTAssertEqual(checkinCalls.get(), 1)
        XCTAssertEqual(store.results.count, 1)
        XCTAssertEqual(store.results.first?.state, SignState.success)
        XCTAssertEqual(store.results.first?.strategyId, "APP_SCAN_CHECKIN")
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

    // MARK: - Auto Check-In After QR Scan

    @MainActor
    func testApplyQrInputAutoStartChecksInOnlySelectedEnabledAccounts() async throws {
        let profile = try TestBundleResources.loadProtocolProfile()
        let vault = InMemoryAccountVault()
        let seenAuths = LockedBox<[String]>([])
        let seenCheckInAuths = LockedBox<[String]>([])

        let session = MockNetworkSupport.makeSession { request in
            let auth = MockNetworkSupport.headerValue("Authorization", in: request) ?? ""
            seenAuths.withLock { $0.append(auth) }
            if request.url?.path == "/api/v3/app/scan" {
                return .json(200, #"{"code":0,"msg":"OK","data":{"type":"checkin","value":"1529274209982060032"}}"#)
            }
            seenCheckInAuths.withLock { $0.append(auth) }
            return .json(200, #"{"code":0,"msg":"签到成功"}"#)
        }

        let store = AppStore(vault: vault, profile: profile, session: session)
        try store.addOrUpdateAccount(makeAccount(id: "acc-1", label: "账号1", bearer: "tok-1"))
        try store.addOrUpdateAccount(makeAccount(id: "acc-2", label: "账号2", bearer: "tok-2"))
        try store.addOrUpdateAccount(makeAccount(id: "acc-3", label: "账号3", bearer: "tok-3"))

        // 3 个已启用账号中仅保留 2 个勾选（取消 acc-2）
        store.toggleSelection(accountId: "acc-2")
        XCTAssertEqual(store.selectedEnabledAccounts.map(\.id), ["acc-1", "acc-3"])

        store.applyQrInput(
            "https://www.yuketang.cn/api/v3/lesson/checkin?c=dyn99&t=1763900000&s=sig99&lessonId=5050",
            autoStartCheckIn: true
        )

        XCTAssertTrue(store.isCheckingIn)
        XCTAssertEqual(store.checkInTotalCount, 2)
        XCTAssertEqual(store.currentTicket?.kind, TicketKind.dynamicCheckin)
        XCTAssertEqual(store.lastBatchTicket, store.currentTicket)
        XCTAssertEqual(store.toastMessage, "已识别签到码，正在为 2 个账号自动签到")

        var ticks = 0
        while store.isCheckingIn && ticks < 100 {
            ticks += 1
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertFalse(store.isCheckingIn)
        XCTAssertEqual(store.lastBatchTicket, store.currentTicket)
        XCTAssertEqual(store.results.count, 2)
        XCTAssertEqual(Set(store.results.map(\.accountId)), Set(["acc-1", "acc-3"]))
        XCTAssertTrue(store.results.allSatisfy { $0.state == .success })
        XCTAssertEqual(seenCheckInAuths.get().count, 2)
        XCTAssertEqual(Set(seenCheckInAuths.get()), Set(["Bearer tok-1", "Bearer tok-3"]))
        XCTAssertEqual(Set(seenAuths.get()), Set(["Bearer tok-1", "Bearer tok-3"]), "未勾选账号 tok-2 绝不可发出任何网络请求")
        XCTAssertEqual(store.toastMessage, "签到完成：成功 2 / 2")
    }

    @MainActor
    func testApplyQrInputAutoStartWhenNoAccountsSelectedKeepsTicketAndSkipsNetwork() async throws {
        let profile = try TestBundleResources.loadProtocolProfile()
        let vault = InMemoryAccountVault()
        let requestCount = LockedBox(0)

        let session = MockNetworkSupport.makeSession { _ in
            requestCount.withLock { $0 += 1 }
            return .json(200, #"{"code":0,"msg":"签到成功"}"#)
        }

        let store = AppStore(vault: vault, profile: profile, session: session)
        try store.addOrUpdateAccount(makeAccount(id: "acc-1", label: "账号1", bearer: "tok-1"))
        try store.addOrUpdateAccount(makeAccount(id: "acc-disabled", label: "停用账号", bearer: "tok-disabled", enabled: false))
        store.toggleSelection(accountId: "acc-1")
        XCTAssertTrue(store.selectedEnabledAccounts.isEmpty)

        store.applyQrInput(
            "https://www.yuketang.cn/api/v3/lesson/checkin?c=nosel&t=1763900000&s=sig&lessonId=6060",
            autoStartCheckIn: true
        )

        XCTAssertEqual(store.currentTicket?.kind, TicketKind.dynamicCheckin)
        XCTAssertEqual(store.currentTicket?.lessonId, "6060")
        XCTAssertFalse(store.isCheckingIn)
        XCTAssertNil(store.lastBatchTicket)
        XCTAssertTrue(store.results.isEmpty)
        XCTAssertEqual(store.toastMessage, "已识别签到码，请先选择至少一个已启用账号")
        XCTAssertEqual(requestCount.get(), 0)

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(store.isCheckingIn)
        XCTAssertEqual(requestCount.get(), 0)
    }

    @MainActor
    func testApplyQrInputAutoStartSkipsLoginUnknownAndUntrustedHost() async throws {
        let profile = try TestBundleResources.loadProtocolProfile()
        let vault = InMemoryAccountVault()
        let requestCount = LockedBox(0)

        let session = MockNetworkSupport.makeSession { _ in
            requestCount.withLock { $0 += 1 }
            return .json(200, #"{"code":0,"msg":"不应触发网络请求"}"#)
        }

        let store = AppStore(vault: vault, profile: profile, session: session)
        try store.addOrUpdateAccount(makeAccount(id: "acc-1", label: "账号1", bearer: "tok-1"))

        // 1) 登录码：不自动签到
        store.applyQrInput(
            "https://www.yuketang.cn/v/index/qrconnect?qrContent=login-demo-token",
            autoStartCheckIn: true
        )
        XCTAssertEqual(store.currentTicket?.kind, TicketKind.login)
        XCTAssertFalse(store.isCheckingIn)
        XCTAssertNil(store.lastBatchTicket)
        XCTAssertEqual(
            store.toastMessage,
            "这是登录二维码而非课堂签到码；如需添加账号请前往「账号」页使用手机号验证码登录或手动导入"
        )
        XCTAssertEqual(requestCount.get(), 0)

        // 2) 未知码：不自动签到
        store.applyQrInput("hello-not-a-raincheck-qr", autoStartCheckIn: true)
        XCTAssertEqual(store.currentTicket?.kind, TicketKind.unknown)
        XCTAssertFalse(store.isCheckingIn)
        XCTAssertNil(store.lastBatchTicket)
        XCTAssertEqual(store.toastMessage, "未识别为标准签到码，已暂停自动签到")
        XCTAssertEqual(requestCount.get(), 0)

        // 3) 非受信任外部域名：不自动提交凭据
        store.applyQrInput(
            "https://evil.example/steal?c=bad1&t=1763900000&s=sig1&lessonId=7070",
            autoStartCheckIn: true
        )
        XCTAssertEqual(store.currentTicket?.kind, TicketKind.dynamicCheckin)
        XCTAssertFalse(store.isCurrentTicketHostTrusted())
        XCTAssertFalse(store.isCheckingIn)
        XCTAssertNil(store.lastBatchTicket)
        XCTAssertEqual(store.toastMessage, "识别到非受信任域名，已暂停自动签到，请核对后再手动执行")
        XCTAssertEqual(requestCount.get(), 0)

        // 4) 明文 HTTP 降级域名：同样视为非受信任并暂停自动签到
        store.applyQrInput(
            "http://www.yuketang.cn/api/v3/lesson/checkin?c=bad2&t=1763900000&s=sig2&lessonId=7071",
            autoStartCheckIn: true
        )
        XCTAssertEqual(store.currentTicket?.kind, TicketKind.dynamicCheckin)
        XCTAssertFalse(store.isCurrentTicketHostTrusted())
        XCTAssertFalse(store.isCheckingIn)
        XCTAssertNil(store.lastBatchTicket)
        XCTAssertEqual(store.toastMessage, "识别到非受信任域名，已暂停自动签到，请核对后再手动执行")
        XCTAssertEqual(requestCount.get(), 0)

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(store.isCheckingIn)
        XCTAssertTrue(store.results.isEmpty)
        XCTAssertEqual(requestCount.get(), 0)
    }

    @MainActor
    func testApplyQrInputDefaultDoesNotAutoStartCheckIn() async throws {
        let profile = try TestBundleResources.loadProtocolProfile()
        let vault = InMemoryAccountVault()
        let requestCount = LockedBox(0)

        let session = MockNetworkSupport.makeSession { _ in
            requestCount.withLock { $0 += 1 }
            return .json(200, #"{"code":0,"msg":"签到成功"}"#)
        }

        let store = AppStore(vault: vault, profile: profile, session: session)
        try store.addOrUpdateAccount(makeAccount(id: "acc-1", label: "账号1", bearer: "tok-1"))

        store.applyQrInput("https://www.yuketang.cn/api/v3/lesson/checkin?c=def1&t=1763900000&s=sig1&lessonId=8080")
        XCTAssertEqual(store.currentTicket?.kind, TicketKind.dynamicCheckin)
        XCTAssertTrue(store.isCurrentTicketHostTrusted())
        XCTAssertEqual(store.selectedEnabledAccounts.count, 1)
        XCTAssertFalse(store.isCheckingIn)
        XCTAssertNil(store.lastBatchTicket)
        XCTAssertEqual(store.toastMessage, "已识别动态签到码")
        XCTAssertEqual(requestCount.get(), 0)

        store.applyQrInput("lessonId=8081")
        XCTAssertEqual(store.currentTicket?.kind, TicketKind.lessonOnly)
        XCTAssertFalse(store.isCheckingIn)
        XCTAssertNil(store.lastBatchTicket)
        XCTAssertEqual(store.toastMessage, "已识别课堂签到目标")
        XCTAssertEqual(requestCount.get(), 0)

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(store.isCheckingIn)
        XCTAssertEqual(requestCount.get(), 0)
    }

    @MainActor
    func testApplyQrInputAutoStartGuardsInFlightBatchAndSupportsDryRun() async throws {
        let profile = try TestBundleResources.loadProtocolProfile()
        let vault = InMemoryAccountVault()
        let requestCount = LockedBox(0)

        let session = MockNetworkSupport.makeSession { _ in
            requestCount.withLock { $0 += 1 }
            return .json(200, #"{"code":0,"msg":"演练模式不应发起请求"}"#)
        }

        let store = AppStore(vault: vault, profile: profile, session: session)
        try store.addOrUpdateAccount(makeAccount(id: "acc-1", label: "账号1", bearer: "tok-1"))
        try store.addOrUpdateAccount(makeAccount(id: "acc-2", label: "账号2", bearer: "tok-2"))
        store.dryRun = true

        store.applyQrInput("lessonId=9091", autoStartCheckIn: true)
        XCTAssertTrue(store.isCheckingIn)
        XCTAssertEqual(store.currentTicket?.kind, TicketKind.lessonOnly)
        XCTAssertEqual(store.lastBatchTicket?.lessonId, "9091")
        XCTAssertEqual(store.toastMessage, "已识别签到码，正在为 2 个账号演练签到")

        // 签到进行中再次扫码：更新 currentTicket 但不打断进行中的批次
        store.applyQrInput("lessonId=9092", autoStartCheckIn: true)
        XCTAssertTrue(store.isCheckingIn)
        XCTAssertEqual(store.currentTicket?.lessonId, "9092")
        XCTAssertEqual(store.lastBatchTicket?.lessonId, "9091")
        XCTAssertEqual(store.toastMessage, "当前正在签到中，已更新二维码，请稍后或取消后重试")

        var ticks = 0
        while store.isCheckingIn && ticks < 100 {
            ticks += 1
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertFalse(store.isCheckingIn)
        XCTAssertEqual(store.lastBatchTicket?.lessonId, "9091")
        XCTAssertEqual(store.currentTicket?.lessonId, "9092")
        XCTAssertEqual(store.results.count, 2)
        XCTAssertTrue(store.results.allSatisfy { $0.state == .dryRun })
        XCTAssertEqual(requestCount.get(), 0)
    }

    // MARK: - Official RainClassroom 1.3.6 Two-Step Dynamic QR Flow & Diagnostics

    func testOfficialAppScanTwoStepDynamicQrFlowWithZeroActiveLessonCalls() async throws {
        struct CapturedAppReq: Sendable {
            let path: String
            let xClient: String?
            let auth: String?
            let cachePolicyRaw: UInt
            let body: [String: TemplateValue]?
        }

        let profile = try TestBundleResources.loadProtocolProfile()
        let rawQr = "https://www.yuketang.cn/api/v3/lesson/check-in/dynamic-qr-code?c=abc+123&t=1763900000&s=sig+456"
        let ticket = QrCodeParser.parse(rawQr, profile: profile)
        XCTAssertEqual(ticket.kind, .dynamicCheckin)
        XCTAssertNil(ticket.lessonId)

        let captured = LockedBox<[CapturedAppReq]>([])
        let discoverCalls = LockedBox(0)

        let orchestrator = makeOrchestrator(profile: profile) { request in
            let path = request.url?.path ?? ""
            let body = MockNetworkSupport.requestBodyJSON(from: request)
            captured.withLock {
                $0.append(
                    CapturedAppReq(
                        path: path,
                        xClient: MockNetworkSupport.headerValue("x-client", in: request),
                        auth: MockNetworkSupport.headerValue("Authorization", in: request),
                        cachePolicyRaw: request.cachePolicy.rawValue,
                        body: body
                    )
                )
            }
            if path == "/api/v3/classroom/on-lesson-upcoming-exam" {
                discoverCalls.withLock { $0 += 1 }
                return .json(200, #"{"code":0,"data":{"onLessonClassrooms":[]}}"#)
            }
            if path == "/api/v3/app/scan" {
                return .json(
                    200,
                    #"{"code":0,"msg":"OK","data":{"type":"checkin","value":"1529274209982060032","lesson_id":"1529274209982060032"}}"#,
                    headers: ["set-auth": "Bearer app-scan-rotated-tok"]
                )
            }
            if path == "/api/v3/lesson/checkin" {
                return .json(200, #"{"code":0,"msg":"签到成功","data":{"lessonId":"1529274209982060032"}}"#)
            }
            return .json(404, #"{"code":40400,"msg":"接口不存在"}"#)
        }

        let result = await orchestrator.checkIn(account: makeAccount(), ticket: ticket)
        XCTAssertEqual(result.state, .success)
        XCTAssertEqual(result.strategyId, "APP_SCAN_CHECKIN")
        XCTAssertEqual(result.businessCode, 0)
        XCTAssertEqual(discoverCalls.get(), 0, "官方两步扫码必须零前置 discoverActiveLesson 调用")
        XCTAssertEqual(result.refreshedAccount?.bearer, "app-scan-rotated-tok")

        let reqs = captured.get()
        XCTAssertEqual(reqs.map(\.path), ["/api/v3/app/scan", "/api/v3/lesson/checkin"])

        let step1 = try XCTUnwrap(reqs.first)
        XCTAssertEqual(step1.xClient, "app")
        XCTAssertEqual(step1.cachePolicyRaw, URLRequest.CachePolicy.reloadIgnoringLocalAndRemoteCacheData.rawValue)
        XCTAssertEqual(step1.body?["url"]?.stringValue, rawQr, "app/scan 必须原样提交 ticket.raw")

        let step2 = try XCTUnwrap(reqs.last)
        XCTAssertEqual(step2.xClient, "app")
        XCTAssertEqual(step2.auth, "Bearer app-scan-rotated-tok")
        XCTAssertEqual(step2.body?["source"]?.intValue, 21)
        XCTAssertEqual(step2.body?["lessonId"]?.stringValue, "1529274209982060032")
        XCTAssertEqual(step2.body?["joinIfNotIn"]?.boolValue, true)

        // 服务端识别为 login / classroom 时立即终止，不继续盲打签到接口
        let loginCalls = LockedBox(0)
        let loginOrch = makeOrchestrator(profile: profile) { request in
            loginCalls.withLock { $0 += 1 }
            if request.url?.path == "/api/v3/app/scan" {
                return .json(200, #"{"code":0,"data":{"type":"app_web_login","value":"scene-1"}}"#)
            }
            return .json(200, #"{"code":0,"msg":"不应继续调用"}"#)
        }
        let loginRes = await loginOrch.checkIn(account: makeAccount(), ticket: ticket)
        XCTAssertEqual(loginCalls.get(), 1)
        XCTAssertEqual(loginRes.state, .notInClass)
        XCTAssertTrue(loginRes.message.contains("登录二维码"))

        let classroomCalls = LockedBox(0)
        let classroomOrch = makeOrchestrator(profile: profile) { request in
            classroomCalls.withLock { $0 += 1 }
            if request.url?.path == "/api/v3/app/scan" {
                return .json(200, #"{"code":0,"data":{"type":"classroom","value":"889900"}}"#)
            }
            return .json(200, #"{"code":0,"msg":"不应继续调用"}"#)
        }
        let classroomRes = await classroomOrch.checkIn(account: makeAccount(), ticket: ticket)
        XCTAssertEqual(classroomCalls.get(), 1)
        XCTAssertEqual(classroomRes.state, .notInClass)
        XCTAssertTrue(classroomRes.message.contains("889900"))
    }

    func testAppScan51203AndCheckin50070And50019PreserveMappedReasonWithoutClobber() async throws {
        let profile = try TestBundleResources.loadProtocolProfile()
        let rawQr = "https://www.yuketang.cn/api/v3/lesson/check-in/dynamic-qr-code?c=exp1&t=1763900000&s=sig1"
        let ticket = QrCodeParser.parse(rawQr, profile: profile)

        // 1) /api/v3/app/scan 返回 51203 过期：原样保留 scanBean.msg 并立即中止
        let calls51203 = LockedBox(0)
        let orch51203 = makeOrchestrator(profile: profile) { _ in
            calls51203.withLock { $0 += 1 }
            return .json(200, #"{"code":51203,"msg":"动态二维码已过期，请重新扫码"}"#)
        }
        let res51203 = await orch51203.checkIn(account: makeAccount(), ticket: ticket)
        XCTAssertEqual(calls51203.get(), 1)
        XCTAssertEqual(res51203.state, .qrExpired)
        XCTAssertEqual(res51203.strategyId, "APP_SCAN_CHECKIN")
        XCTAssertEqual(res51203.businessCode, 51203)
        XCTAssertTrue(res51203.message.contains("动态二维码已过期，请重新扫码"))
        XCTAssertTrue(res51203.diagnosticReason.contains("51203"))

        // 2) Step 2 返回 50070，后续全部兜底返回 404 HTML：必须保留 50070 与清晰中文原因，绝不被 404/HTML 覆盖
        let discoverCalls50070 = LockedBox(0)
        let orch50070 = makeOrchestrator(profile: profile) { request in
            let path = request.url?.path ?? ""
            if path == "/api/v3/classroom/on-lesson-upcoming-exam" {
                discoverCalls50070.withLock { $0 += 1 }
                return .json(200, #"{"code":0,"data":{"onLessonClassrooms":[]}}"#)
            }
            if path == "/api/v3/app/scan" {
                return .json(200, #"{"code":0,"data":{"type":"checkin","value":"1529274209982060032"}}"#)
            }
            if path == "/api/v3/lesson/checkin",
               MockNetworkSupport.requestBodyJSON(from: request)?["source"]?.intValue == 21 {
                return .json(200, #"{"code":50070,"msg":"DYNAMIC QR CHECK IN REFUSED"}"#)
            }
            return .text(404, "<!DOCTYPE html><html><head><title>404 Not Found</title></head><body>Not Found</body></html>", contentType: "text/html")
        }
        let res50070 = await orch50070.checkIn(account: makeAccount(), ticket: ticket)
        XCTAssertEqual(discoverCalls50070.get(), 0, "Step 1 已获得 lessonId，回退策略无需调用 discoverActiveLesson")
        XCTAssertEqual(res50070.state, .failed)
        XCTAssertEqual(res50070.strategyId, "APP_SCAN_CHECKIN")
        XCTAssertEqual(res50070.businessCode, 50070)
        XCTAssertTrue(res50070.message.contains("动态二维码校验未通过或课堂已结束"))
        XCTAssertTrue(res50070.message.contains("DYNAMIC QR CHECK IN REFUSED"))
        XCTAssertTrue(res50070.diagnosticReason.contains("50070"))

        // 3) Step 2 返回 50019（未绑定学校身份），后续返回空 405：绝不被“身份”误判为 .authExpired，且不被 405 覆盖
        let orch50019 = makeOrchestrator(profile: profile) { request in
            let path = request.url?.path ?? ""
            if path == "/api/v3/app/scan" {
                return .json(200, #"{"code":0,"data":{"type":"checkin","value":"1529274209982060032"}}"#)
            }
            if path == "/api/v3/lesson/checkin",
               MockNetworkSupport.requestBodyJSON(from: request)?["source"]?.intValue == 21 {
                return .json(200, #"{"code":50019,"msg":"school identity required"}"#)
            }
            return .text(405, "")
        }
        let res50019 = await orch50019.checkIn(account: makeAccount(), ticket: ticket)
        XCTAssertEqual(res50019.state, .notInClass, "50019 不得被 authKeywords 中的‘身份’误判为 .authExpired")
        XCTAssertEqual(res50019.strategyId, "APP_SCAN_CHECKIN")
        XCTAssertEqual(res50019.businessCode, 50019)
        XCTAssertTrue(res50019.message.contains("账号未绑定学校身份"))
        XCTAssertTrue(res50019.diagnosticReason.contains("50019"))
    }

    func testHttp403NonAuthRefusalAndHttp404RouteNotFoundDoNotFalseAbortFallback() async throws {
        let profile = try TestBundleResources.loadProtocolProfile()

        // 1) HTTP 403 非鉴权业务拒绝：绝不误判 .authExpired 中断后续策略；并验证 {"success": true} 识别为成功
        let dynNoUrl = QrCodeParser.parse("c=abc&t=1763900000&s=sig&lessonId=888", profile: profile)
        let seenSources = LockedBox<[Int]>([])
        let orch403 = makeOrchestrator(profile: profile) { request in
            let source = MockNetworkSupport.requestBodyJSON(from: request)?["source"]?.intValue ?? -1
            seenSources.withLock { $0.append(source) }
            if source == 14 {
                return .json(403, #"{"code":40301,"msg":"当前来源不允许签到"}"#)
            }
            return .json(200, #"{"success":true,"msg":"ok"}"#)
        }
        let res403 = await orch403.checkIn(account: makeAccount(), ticket: dynNoUrl)
        XCTAssertEqual(res403.state, .success)
        XCTAssertEqual(res403.strategyId, "DYN_TICKET_5")
        XCTAssertEqual(seenSources.get(), [14, 5], "HTTP 403 业务拒绝绝不能错误中止 DYN_TICKET_5 回退")

        // 2) HTTP 404 “接口不存在”：绝不误判 .qrExpired，必须继续尝试 QR_URL_GET
        let seenMethods = LockedBox<[String]>([])
        let orch404 = makeOrchestrator(profile: profile) { request in
            let method = request.httpMethod ?? "GET"
            let path = request.url?.path ?? ""
            seenMethods.withLock { $0.append("\(method) \(path)") }
            if path == "/api/v3/classroom/on-lesson-upcoming-exam" {
                return .json(200, #"{"code":0,"data":{"onLessonClassrooms":[]}}"#)
            }
            if path == "/api/v3/custom/qr-fallback" && method == "POST" {
                return .json(404, #"{"code":40400,"msg":"接口不存在"}"#)
            }
            if path == "/api/v3/custom/qr-fallback" && method == "GET" {
                return .json(200, #"{"code":0,"msg":"GET 签到成功"}"#)
            }
            return .json(404, #"{"code":40400,"msg":"接口不存在"}"#)
        }
        let fallbackTicket = QrCodeParser.parse(
            "https://www.yuketang.cn/api/v3/custom/qr-fallback?c=c1&t=1763900000&s=s1",
            profile: profile
        )
        let res404 = await orch404.checkIn(account: makeAccount(), ticket: fallbackTicket)
        XCTAssertEqual(res404.state, .success)
        XCTAssertEqual(res404.strategyId, "QR_URL_GET")
        XCTAssertTrue(seenMethods.get().contains("POST /api/v3/custom/qr-fallback"))
        XCTAssertTrue(seenMethods.get().contains("GET /api/v3/custom/qr-fallback"))

        // 3) HTML 200 内含 <script> token 字样不误判 .authExpired；HTTP 403 CSRF 正确判 .authExpired
        let htmlWithToken = "<!DOCTYPE html><html><head><title>Service Error</title></head><body><script>const token='abc';</script></body></html>"
        XCTAssertEqual(
            orch403.classify(httpStatus: 200, businessCode: nil, message: nil, bodyText: htmlWithToken, isHtmlBody: true),
            .failed
        )
        XCTAssertEqual(
            orch403.classify(httpStatus: 403, businessCode: nil, message: "CSRF verification failed", bodyText: ""),
            .authExpired
        )
    }

    @MainActor
    func testHtmlEmptyBodyDiagnosticsSameOriginRefererHostMismatchHintAndFailureToast() async throws {
        struct DirectOriginPair: Sendable {
            let origin: String?
            let referer: String?
        }

        let profile = try TestBundleResources.loadProtocolProfile()

        // 1) HTML / 空体响应诊断 + 脱敏 rawSnippet + 跨域名同源 Origin/Referer + 平台域名不一致提示
        let directOrigins = LockedBox<[DirectOriginPair]>([])
        let orchestrator = makeOrchestrator(profile: profile, maxAttemptsPerStrategy: 1, baseBackoffMs: 0) { request in
            let host = request.url?.host?.lowercased() ?? ""
            let path = request.url?.path ?? ""
            if host == "pro.yuketang.cn" {
                directOrigins.withLock {
                    $0.append(
                        DirectOriginPair(
                            origin: MockNetworkSupport.headerValue("Origin", in: request),
                            referer: MockNetworkSupport.headerValue("Referer", in: request)
                        )
                    )
                }
                return .text(404, "")
            }
            if path == "/api/v3/classroom/on-lesson-upcoming-exam" {
                return .json(200, #"{"code":0,"data":{"onLessonClassrooms":[]}}"#)
            }
            return .text(
                502,
                "<!DOCTYPE html><html><head><title>Bad Gateway</title></head><body>Authorization: Bearer SECRET_SHOULD_REDACT</body></html>",
                contentType: "text/html; charset=utf-8"
            )
        }

        let crossHostTicket = QrCodeParser.parse(
            "https://pro.yuketang.cn/api/v3/lesson/check-in/dynamic-qr-code?c=cross1&t=1763900000&s=sig1",
            profile: profile
        )
        let wwwAccount = makeAccount(id: "acc-www", label: "主站账号", host: "www.yuketang.cn")
        let res = await orchestrator.checkIn(account: wwwAccount, ticket: crossHostTicket)

        XCTAssertTrue(res.state.isFailureLike)
        XCTAssertFalse(res.diagnosticReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse(res.message.contains("<!DOCTYPE html>"), "HTML 响应不得直接输出原始 DOCTYPE 标签")
        XCTAssertTrue(res.message.contains("Bad Gateway") || res.message.contains("HTML"))
        XCTAssertTrue(res.message.contains("www.yuketang.cn"), "域名不一致时应提示账号平台域名")
        XCTAssertTrue(res.message.contains("pro.yuketang.cn"), "域名不一致时应提示二维码域名")

        let report = res.diagnosticReportText
        XCTAssertFalse(report.contains("SECRET_SHOULD_REDACT"), "诊断报告绝不能泄露 Bearer 凭据")
        XCTAssertTrue(res.attempts.allSatisfy { !($0.rawSnippet?.contains("SECRET_SHOULD_REDACT") ?? false) })

        let directHeaders = directOrigins.get()
        XCTAssertFalse(directHeaders.isEmpty)
        for pair in directHeaders {
            XCTAssertEqual(pair.origin, "https://pro.yuketang.cn")
            XCTAssertEqual(pair.referer, "https://pro.yuketang.cn/v2/web/index", "直连 QR_URL 必须保持 Origin 与 Referer 同源")
        }

        // 2) AppStore 失败完成 Toast 必须直接携带具体失败原因而非裸“签到完成：成功 0 / 1”
        let vault = InMemoryAccountVault()
        let failSession = MockNetworkSupport.makeSession { _ in
            .json(200, #"{"code":51203,"msg":"二维码已过期，请重新扫码"}"#)
        }
        let store = AppStore(vault: vault, profile: profile, session: failSession)
        try store.addOrUpdateAccount(makeAccount(id: "toast-acc", label: "王同学"))
        store.applyQrInput("https://www.yuketang.cn/api/v3/lesson/check-in/dynamic-qr-code?c=t1&t=1763900000&s=s1")
        store.startCheckIn()

        var ticks = 0
        while store.isCheckingIn && ticks < 100 {
            ticks += 1
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertFalse(store.isCheckingIn)
        let toast = try XCTUnwrap(store.toastMessage)
        XCTAssertTrue(toast.contains("签到失败（0/1）"), "失败 Toast 应包含失败计数: \(toast)")
        XCTAssertTrue(toast.contains("二维码已过期"), "失败 Toast 必须包含具体失败原因: \(toast)")
    }

    // MARK: - Continuous Scanner Session & Persistent History

    @MainActor
    private func waitUntilIdle(_ store: AppStore, maxTicks: Int = 150) async throws {
        var ticks = 0
        while store.isCheckingIn && ticks < maxTicks {
            ticks += 1
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @MainActor
    func testContinuousScannerSessionAutoDisablesSucceededAccountsAndSkipsOnRepeatScan() async throws {
        let profile = try TestBundleResources.loadProtocolProfile()
        let vault = InMemoryAccountVault()
        let historyStore = InMemoryCheckInHistoryStore()

        let authCalls = LockedBox<[String: Int]>([:])
        let allowBToSucceed = LockedBox(false)

        let session = MockNetworkSupport.makeSession { request in
            let auth = MockNetworkSupport.headerValue("Authorization", in: request) ?? ""
            authCalls.withLock { $0[auth, default: 0] += 1 }

            let path = request.url?.path ?? ""
            if path == "/api/v3/app/scan" {
                if auth == "Bearer tok-b" && !allowBToSucceed.get() {
                    return .json(200, #"{"code":51203,"msg":"动态二维码已过期，请重扫"}"#)
                }
                return .json(200, #"{"code":0,"data":{"type":"checkin","value":"900001"}}"#)
            }
            if path == "/api/v3/lesson/checkin" {
                return .json(200, #"{"code":0,"msg":"签到成功"}"#)
            }
            return .json(404, #"{"code":40400,"msg":"接口不存在"}"#)
        }

        let store = AppStore(vault: vault, historyStore: historyStore, profile: profile, session: session)
        try store.addOrUpdateAccount(makeAccount(id: "acc-a", label: "张三", bearer: "tok-a"))
        try store.addOrUpdateAccount(makeAccount(id: "acc-b", label: "李四", bearer: "tok-b"))

        let qr1 = "https://www.yuketang.cn/api/v3/lesson/check-in/dynamic-qr-code?c=scan1&t=1763900000&s=sig1"
        store.beginScannerSession()
        XCTAssertTrue(store.isScannerSessionActive)
        XCTAssertEqual(store.scannerSessionTotalCount, 2)
        XCTAssertEqual(store.scannerSessionSucceededCount, 0)
        XCTAssertEqual(store.scannerSessionRemainingAccounts.map(\.id), ["acc-a", "acc-b"])

        // 第 1 次扫码：张三成功、李四失败 -> 张三加入本轮已成功禁用名单，悬浮通知点名张三成功并附李四失败摘要
        store.handleContinuousScannerQr(qr1)
        try await waitUntilIdle(store)

        XCTAssertEqual(store.scannerSessionSucceededAccountIds, Set(["acc-a"]))
        XCTAssertEqual(store.scannerSessionSucceededCount, 1)
        XCTAssertEqual(store.scannerSessionTotalCount, 2)
        XCTAssertEqual(store.scannerSessionRemainingAccounts.map(\.id), ["acc-b"])
        XCTAssertEqual(store.scannerSessionSucceededLabels, ["张三"])

        let note1 = try XCTUnwrap(store.scannerOverlayNotification)
        XCTAssertEqual(note1.kind, .partial)
        XCTAssertEqual(note1.succeededLabels, ["张三"])
        XCTAssertEqual(note1.failedSummaries.count, 1)
        XCTAssertTrue(note1.failedSummaries[0].contains("李四"))
        XCTAssertTrue(note1.failedSummaries[0].contains("51203") || note1.failedSummaries[0].contains("过期"))
        XCTAssertEqual(note1.sessionSucceededCount, 1)
        XCTAssertEqual(note1.sessionTotalCount, 2)

        let aCallsAfterScan1 = authCalls.get()["Bearer tok-a", default: 0]
        let bCallsAfterScan1 = authCalls.get()["Bearer tok-b", default: 0]
        XCTAssertEqual(aCallsAfterScan1, 2)
        XCTAssertEqual(bCallsAfterScan1, 1)

        // 第 2 次再次扫同一个码：仅提交剩余未成功的李四，张三零请求！
        allowBToSucceed.withLock { $0 = true }
        store.handleContinuousScannerQr(qr1)
        try await waitUntilIdle(store)

        XCTAssertEqual(
            authCalls.get()["Bearer tok-a", default: 0],
            aCallsAfterScan1,
            "本轮已成功的账号再次扫同一个码时绝不能发送任何网络请求"
        )
        XCTAssertEqual(
            authCalls.get()["Bearer tok-b", default: 0],
            bCallsAfterScan1 + 2,
            "仅剩失败账号应发起请求"
        )
        XCTAssertEqual(store.scannerSessionSucceededAccountIds, Set(["acc-a", "acc-b"]))
        XCTAssertEqual(store.scannerSessionSucceededCount, 2)
        XCTAssertEqual(store.scannerSessionTotalCount, 2)
        XCTAssertTrue(store.scannerSessionRemainingAccounts.isEmpty)
        XCTAssertEqual(store.results.count, 2, "同会话二次补签应保留首次成功账号结果并更新失败账号结果")
        XCTAssertTrue(store.results.allSatisfy { $0.state.isSuccessLike })

        let note2 = try XCTUnwrap(store.scannerOverlayNotification)
        XCTAssertEqual(note2.kind, .success)
        XCTAssertEqual(note2.succeededLabels, ["李四"])
        XCTAssertTrue(note2.failedSummaries.isEmpty)
        XCTAssertEqual(note2.sessionSucceededCount, 2)
        XCTAssertEqual(note2.sessionTotalCount, 2)

        // 第 3 次（全员均已成功）扫同一个码及刷新后的码：必须零请求并弹出全员已完成悬浮通知
        let callsBeforeScan3 = authCalls.get()
        store.handleContinuousScannerQr(qr1)
        XCTAssertFalse(store.isCheckingIn)
        XCTAssertEqual(authCalls.get(), callsBeforeScan3, "全员已成功后再扫同码必须零网络请求")

        let note3 = try XCTUnwrap(store.scannerOverlayNotification)
        XCTAssertEqual(note3.kind, .success)
        XCTAssertEqual(note3.title, "本轮所选账号已全部签到成功")
        XCTAssertEqual(note3.succeededLabels, ["张三", "李四"])
        XCTAssertEqual(note3.sessionSucceededCount, 2)
        XCTAssertEqual(note3.sessionTotalCount, 2)

        store.handleContinuousScannerQr("https://www.yuketang.cn/api/v3/lesson/check-in/dynamic-qr-code?c=scan2&t=1763900010&s=sig2")
        XCTAssertFalse(store.isCheckingIn)
        XCTAssertEqual(authCalls.get(), callsBeforeScan3, "全员已成功后再扫刷新码同样必须零网络请求")

        store.dismissScannerOverlayNotification()
        XCTAssertNil(store.scannerOverlayNotification)
        XCTAssertEqual(store.history.count, 2, "两次真实扫码批次应各自保留完整历史记录")
    }

    @MainActor
    func testEndAndBeginScannerSessionResetsDisabledAccountsWithoutMutatingAccountPool() async throws {
        let profile = try TestBundleResources.loadProtocolProfile()
        let vault = InMemoryAccountVault()
        let authCalls = LockedBox<[String: Int]>([:])

        let session = MockNetworkSupport.makeSession { request in
            let auth = MockNetworkSupport.headerValue("Authorization", in: request) ?? ""
            authCalls.withLock { $0[auth, default: 0] += 1 }
            return .json(200, #"{"code":0,"msg":"签到成功"}"#)
        }

        let store = AppStore(vault: vault, profile: profile, session: session)
        try store.addOrUpdateAccount(makeAccount(id: "acc-a", label: "甲同学", bearer: "tok-a"))
        try store.addOrUpdateAccount(makeAccount(id: "acc-b", label: "乙同学", bearer: "tok-b"))

        // 会话 1：两个账号全部签到成功
        store.beginScannerSession()
        store.handleContinuousScannerQr("lessonId=3030")
        try await waitUntilIdle(store)

        XCTAssertEqual(store.scannerSessionSucceededAccountIds, Set(["acc-a", "acc-b"]))
        XCTAssertEqual(authCalls.get()["Bearer tok-a", default: 0], 1)
        XCTAssertEqual(authCalls.get()["Bearer tok-b", default: 0], 1)
        XCTAssertTrue(store.accounts.allSatisfy(\.enabled), "会话级禁用绝不得修改 Account.enabled")
        XCTAssertEqual(store.selectedAccountIds, Set(["acc-a", "acc-b"]), "会话级禁用绝不得修改 selectedAccountIds")

        // 退出扫码页并重新进入：自动重置会话级已成功禁用名单，账号池状态保持原样
        store.endScannerSession()
        XCTAssertFalse(store.isScannerSessionActive)
        XCTAssertTrue(store.scannerSessionSucceededAccountIds.isEmpty)
        XCTAssertTrue(store.scannerSessionTargetAccountIds.isEmpty)
        XCTAssertNil(store.scannerOverlayNotification)
        XCTAssertTrue(store.accounts.allSatisfy(\.enabled))
        XCTAssertEqual(store.selectedAccountIds, Set(["acc-a", "acc-b"]))

        store.beginScannerSession()
        XCTAssertTrue(store.isScannerSessionActive)
        XCTAssertTrue(store.scannerSessionSucceededAccountIds.isEmpty)
        XCTAssertEqual(store.scannerSessionRemainingAccounts.map(\.id), ["acc-a", "acc-b"])

        // 会话 2：再次扫码两个账号均恢复提交
        store.handleContinuousScannerQr("lessonId=3030")
        try await waitUntilIdle(store)

        XCTAssertEqual(authCalls.get()["Bearer tok-a", default: 0], 2)
        XCTAssertEqual(authCalls.get()["Bearer tok-b", default: 0], 2)
        XCTAssertEqual(store.scannerSessionSucceededAccountIds, Set(["acc-a", "acc-b"]))
    }

    @MainActor
    func testContinuousScannerGuardsInvalidTicketsAndDryRunDoesNotDisableAccounts() async throws {
        let profile = try TestBundleResources.loadProtocolProfile()
        let vault = InMemoryAccountVault()
        let requestCount = LockedBox(0)

        let session = MockNetworkSupport.makeSession { _ in
            requestCount.withLock { $0 += 1 }
            return .json(200, #"{"code":0,"msg":"不应被调用"}"#)
        }

        let store = AppStore(vault: vault, profile: profile, session: session)
        try store.addOrUpdateAccount(makeAccount(id: "acc-1", label: "账号1", bearer: "tok-1"))
        store.beginScannerSession()

        // 1) 空白内容
        store.handleContinuousScannerQr("   \n\t ")
        XCTAssertEqual(store.scannerOverlayNotification?.kind, .warning)
        XCTAssertFalse(store.isCheckingIn)
        XCTAssertEqual(requestCount.get(), 0)

        // 2) 登录二维码
        store.handleContinuousScannerQr("https://www.yuketang.cn/v2/web/login?scene=xyz999")
        XCTAssertEqual(store.currentTicket?.kind, .login)
        XCTAssertEqual(store.scannerOverlayNotification?.kind, .warning)
        XCTAssertFalse(store.isCheckingIn)
        XCTAssertEqual(requestCount.get(), 0)

        // 3) 未识别内容
        store.handleContinuousScannerQr("random-non-checkin-qr-payload")
        XCTAssertEqual(store.currentTicket?.kind, .unknown)
        XCTAssertEqual(store.scannerOverlayNotification?.kind, .warning)
        XCTAssertFalse(store.isCheckingIn)
        XCTAssertEqual(requestCount.get(), 0)

        // 4) 非受信任域名
        store.handleContinuousScannerQr("https://evil.example/api/v3/lesson/check-in/dynamic-qr-code?c=abc&t=1763900000&s=sig")
        XCTAssertEqual(store.currentTicket?.kind, .dynamicCheckin)
        XCTAssertFalse(store.isCurrentTicketHostTrusted())
        XCTAssertEqual(store.scannerOverlayNotification?.kind, .warning)
        XCTAssertFalse(store.isCheckingIn)
        XCTAssertEqual(requestCount.get(), 0)

        // 5) 演练模式：零请求，展示 .info 通知，且不会把账号加入本轮成功禁用名单
        store.dryRun = true
        store.handleContinuousScannerQr("https://www.yuketang.cn/api/v3/lesson/check-in/dynamic-qr-code?c=dry1&t=1763900000&s=sig1")
        try await waitUntilIdle(store)
        XCTAssertEqual(requestCount.get(), 0)
        XCTAssertEqual(store.scannerOverlayNotification?.kind, .info)
        XCTAssertTrue(store.scannerSessionSucceededAccountIds.isEmpty, "演练模式不得将账号加入本轮成功禁用名单")
        XCTAssertEqual(store.history.count, 1)
        XCTAssertEqual(store.history.first?.dryRun, true)

        // 6) 未选择任何账号
        store.dryRun = false
        store.selectedAccountIds = []
        store.handleContinuousScannerQr("lessonId=4040")
        XCTAssertEqual(store.scannerOverlayNotification?.kind, .warning)
        XCTAssertFalse(store.isCheckingIn)
        XCTAssertEqual(requestCount.get(), 0)
    }

    @MainActor
    func testPersistentCheckInHistorySavesFullTracesReloadsDeletesAndExcludesSecrets() async throws {
        let profile = try TestBundleResources.loadProtocolProfile()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("raincheck-history-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let historyURL = tempDir.appendingPathComponent("checkin_history.json")
        let vault = InMemoryAccountVault()

        let session = MockNetworkSupport.makeSession { request in
            let path = request.url?.path ?? ""
            if path == "/api/v3/app/scan" {
                return .json(
                    200,
                    #"{"code":51203,"msg":"动态二维码已过期","debug":"sessionid=SECRET_SNIPPET_SID_333"}"#
                )
            }
            return .json(
                200,
                #"{"code":0,"msg":"签到成功","note":"Bearer SECRET_SNIPPET_BEARER_888"}"#,
                headers: ["set-auth": "Bearer SECRET_ROTATED_HIST_999"]
            )
        }

        let store = AppStore(
            vault: vault,
            historyStore: FileCheckInHistoryStore(fileURL: historyURL),
            profile: profile,
            session: session
        )
        try store.addOrUpdateAccount(
            makeAccount(
                id: "hist-acc-1",
                label: "测试同学",
                bearer: "SECRET_ACC_BEARER_111",
                sessionId: "SECRET_ACC_SID_222",
                csrfToken: "SECRET_ACC_CSRF_333"
            )
        )

        // 批次 1：课堂码签到成功
        store.applyQrInput("lessonId=7001")
        store.startCheckIn()
        try await waitUntilIdle(store)

        // 批次 2：含敏感 token 参数的动态二维码失败（保留完整 AttemptTrace 与 rawSnippet）
        let rawQrWithSecret = "https://www.yuketang.cn/api/v3/lesson/check-in/dynamic-qr-code?c=dyn2&t=1763900000&s=sig2&lessonId=7002&token=SECRET_URL_TOK_555"
        store.applyQrInput(rawQrWithSecret)
        store.startCheckIn()
        try await waitUntilIdle(store)

        // 1) 内存最新倒序与完整轨迹校验
        XCTAssertEqual(store.history.count, 2)
        let latest = store.history[0]
        let older = store.history[1]

        XCTAssertEqual(latest.ticketKind, .dynamicCheckin)
        XCTAssertEqual(latest.ticketLessonId, "7002")
        XCTAssertEqual(latest.ticketHost, "www.yuketang.cn")
        XCTAssertEqual(latest.succeededCount, 0)
        XCTAssertEqual(latest.failedCount, 1)
        XCTAssertEqual(latest.totalCount, 1)
        XCTAssertTrue(latest.ticketRaw.contains("token=[REDACTED]"), "历史票据 URL 必须脱敏 token 参数")
        XCTAssertFalse(latest.ticketRaw.contains("SECRET_URL_TOK_555"))
        XCTAssertNil(latest.results.first?.refreshedAccount)
        let latestTrace = try XCTUnwrap(latest.results.first?.attempts.first)
        XCTAssertEqual(latestTrace.strategyId, "APP_SCAN_CHECKIN")
        XCTAssertEqual(latestTrace.businessCode, 51203)
        XCTAssertEqual(latestTrace.httpStatus, 200)
        XCTAssertNotNil(latestTrace.rawSnippet)
        XCTAssertFalse(latestTrace.rawSnippet?.contains("SECRET_SNIPPET_SID_333") ?? false)

        XCTAssertEqual(older.ticketKind, .lessonOnly)
        XCTAssertEqual(older.ticketLessonId, "7001")
        XCTAssertEqual(older.succeededCount, 1)
        XCTAssertEqual(older.succeededLabels, ["测试同学"])
        XCTAssertNil(older.results.first?.refreshedAccount)

        // 2) 磁盘 JSON 持久化、零明文凭据与排除 iCloud 备份校验
        let diskData = try Data(contentsOf: historyURL)
        let diskText = try XCTUnwrap(String(data: diskData, encoding: .utf8))
        XCTAssertTrue(diskText.contains("APP_SCAN_CHECKIN"))
        XCTAssertTrue(diskText.contains("动态二维码已过期"))
        for secret in [
            "SECRET_ACC_BEARER_111",
            "SECRET_ACC_SID_222",
            "SECRET_ACC_CSRF_333",
            "SECRET_ROTATED_HIST_999",
            "SECRET_SNIPPET_BEARER_888",
            "SECRET_SNIPPET_SID_333",
            "SECRET_URL_TOK_555"
        ] {
            XCTAssertFalse(diskText.contains(secret), "历史磁盘 JSON 绝不能包含任何明文凭据: \(secret)")
        }

        let jsonArray = try XCTUnwrap(JSONSerialization.jsonObject(with: diskData) as? [[String: Any]])
        XCTAssertEqual(jsonArray.count, 2)
        for entryObj in jsonArray {
            let resultObjs = try XCTUnwrap(entryObj["results"] as? [[String: Any]])
            for resObj in resultObjs {
                for forbiddenKey in ["refreshedAccount", "bearer", "sessionId", "csrfToken"] {
                    XCTAssertNil(resObj[forbiddenKey], "SignResult JSON 绝不能包含敏感键: \(forbiddenKey)")
                }
            }
        }

        let freshHistoryURL = URL(fileURLWithPath: historyURL.path)
        let resourceValues = try freshHistoryURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(resourceValues.isExcludedFromBackup, true)

        let reportText = latest.diagnosticReportText
        XCTAssertTrue(reportText.contains("测试同学"))
        XCTAssertTrue(reportText.contains("APP_SCAN_CHECKIN"))
        XCTAssertFalse(reportText.contains("SECRET_URL_TOK_555"))
        XCTAssertFalse(reportText.contains("SECRET_SNIPPET_SID_333"))

        // 3) 重新实例化 AppStore 模拟冷启动重载，验证完整轨迹与 rawSnippet 恢复
        let reloadedStore = AppStore(
            vault: vault,
            historyStore: FileCheckInHistoryStore(fileURL: historyURL),
            profile: profile,
            session: session
        )
        XCTAssertEqual(reloadedStore.history.count, 2)
        XCTAssertEqual(reloadedStore.history[0].id, latest.id)
        XCTAssertEqual(reloadedStore.history[0].results.first?.attempts.first?.rawSnippet, latestTrace.rawSnippet)
        XCTAssertEqual(reloadedStore.history[1].id, older.id)

        // 4) 单条 & 全量脱敏导出验证
        let singleExportURL = try reloadedStore.exportHistoryEntryReportURL(latest)
        defer { try? FileManager.default.removeItem(at: singleExportURL) }
        let singleExportText = try String(contentsOf: singleExportURL, encoding: .utf8)
        XCTAssertTrue(singleExportText.contains(latest.id))
        XCTAssertFalse(singleExportText.contains("SECRET_ACC_BEARER_111"))

        let allExportURL = try reloadedStore.exportAllHistoryReportURL()
        defer { try? FileManager.default.removeItem(at: allExportURL) }
        let allExportData = try Data(contentsOf: allExportURL)
        let decodedAll = try JSONDecoder().decode(HistoryExportReport.self, from: allExportData)
        XCTAssertEqual(decodedAll.totalEntries, 2)

        // 5) 单条删除当前结果 + 单条删除历史记录 + 持久化验证
        let currentResult = try XCTUnwrap(store.results.first)
        store.deleteResult(id: currentResult.id)
        XCTAssertTrue(store.results.isEmpty)
        XCTAssertNil(store.lastBatchTicket)

        reloadedStore.deleteHistoryEntry(id: latest.id)
        XCTAssertEqual(reloadedStore.history.map(\.id), [older.id])

        let afterDeleteStore = AppStore(
            vault: vault,
            historyStore: FileCheckInHistoryStore(fileURL: historyURL),
            profile: profile,
            session: session
        )
        XCTAssertEqual(afterDeleteStore.history.map(\.id), [older.id])

        // 6) 清空全部历史记录 + 持久化验证
        afterDeleteStore.clearHistory()
        XCTAssertTrue(afterDeleteStore.history.isEmpty)

        let afterClearStore = AppStore(
            vault: vault,
            historyStore: FileCheckInHistoryStore(fileURL: historyURL),
            profile: profile,
            session: session
        )
        XCTAssertTrue(afterClearStore.history.isEmpty)

        // 7) 文件存储上限截断验证（保留最新 maxEntries 条）
        let cappedURL = tempDir.appendingPathComponent("capped_history.json")
        let cappedStore = FileCheckInHistoryStore(fileURL: cappedURL, maxEntries: 3)
        let sampleEntries = (1...5).map { idx in
            CheckInHistoryEntry(
                id: "entry-\(idx)",
                createdAtMs: Int64(1_700_000_000_000 + idx),
                ticketRaw: "lessonId=\(idx)",
                ticketKind: .lessonOnly,
                ticketSummary: "课堂签到 · \(idx)",
                ticketLessonId: "\(idx)",
                dryRun: false,
                results: []
            )
        }
        cappedStore.save(sampleEntries)
        XCTAssertEqual(cappedStore.load().map(\.id), ["entry-1", "entry-2", "entry-3"])
    }

    func testContinuousScanDeduplicatorSuppressesSteadySameCodeAndAllowsRotationOrReEntry() {
        let sec: UInt64 = 1_000_000_000
        var dedup = ContinuousScanDeduplicator(
            absenceResetNanoseconds: 1_200_000_000,
            minRetriggerNanoseconds: 2_000_000_000
        )

        // 1) 首次扫到 qr1 立即触发
        XCTAssertTrue(dedup.shouldDeliverLiveScan("qr1", now: 0, isBusy: false))

        // 2) 签到进行中：同码刷新存在时间且返回 false；旋转后的新码在忙碌期也返回 false 且不覆盖 lastDeliveredCode
        XCTAssertFalse(dedup.shouldDeliverLiveScan("qr1", now: 200_000_000, isBusy: true))
        XCTAssertFalse(dedup.shouldDeliverLiveScan("qr1", now: 500_000_000, isBusy: true))
        XCTAssertFalse(dedup.shouldDeliverLiveScan("qr2", now: 700_000_000, isBusy: true))
        XCTAssertEqual(dedup.lastDeliveredCode, "qr1")

        // 3) 签到结束后若镜头持续对准同一个 qr1（每 150ms 一帧持续 10 秒），绝不周期性重复触发
        var t: UInt64 = 800_000_000
        for _ in 0..<70 {
            XCTAssertFalse(
                dedup.shouldDeliverLiveScan("qr1", now: t, isBusy: false),
                "镜头持续对准同一二维码时不应重复触发"
            )
            t += 150_000_000
        }

        // 4) 动态码刷新为 qr2 时零延迟立即触发
        let rotateAt = t + 100_000_000
        XCTAssertTrue(dedup.shouldDeliverLiveScan("qr2", now: rotateAt, isBusy: false))
        XCTAssertEqual(dedup.lastDeliveredCode, "qr2")

        // 5) 短暂失焦 0.4s (< 1.2s) 回到 qr2 不会误重扫
        XCTAssertFalse(dedup.shouldDeliverLiveScan("qr2", now: rotateAt + 400_000_000, isBusy: false))

        // 6) 主动移开镜头 1.5s (>= 1.2s) 且距上次触发 >= 2.0s 后再对准 qr2，允许重扫一次，随后持续对准再次静默
        let reenterAt = rotateAt + 2_500_000_000
        XCTAssertTrue(dedup.shouldDeliverLiveScan("qr2", now: reenterAt, isBusy: false))
        XCTAssertFalse(dedup.shouldDeliverLiveScan("qr2", now: reenterAt + 150_000_000, isBusy: false))

        // 7) 相册手动选图记录与 reset() 行为
        dedup.recordManualDelivery("qr-photo", now: reenterAt + sec)
        XCTAssertEqual(dedup.lastDeliveredCode, "qr-photo")
        XCTAssertFalse(dedup.shouldDeliverLiveScan("qr-photo", now: reenterAt + sec + 200_000_000, isBusy: false))

        dedup.reset()
        XCTAssertNil(dedup.lastDeliveredCode)
        XCTAssertTrue(dedup.shouldDeliverLiveScan("qr-photo", now: reenterAt + 2 * sec, isBusy: false))
    }

    @MainActor
    func testContinuousScannerPreservesCurrentTicketOnNoOpTracksSkippedCountAndIsolatesSessionReopen() async throws {
        let profile = try TestBundleResources.loadProtocolProfile()
        let vault = InMemoryAccountVault()
        let historyStore = InMemoryCheckInHistoryStore()
        let allowB = LockedBox(false)
        let slowDelay = LockedBox(false)
        let requestCount = LockedBox(0)

        let session = MockNetworkSupport.makeSession { request in
            requestCount.withLock { $0 += 1 }
            let auth = MockNetworkSupport.headerValue("Authorization", in: request) ?? ""
            if slowDelay.get() {
                Thread.sleep(forTimeInterval: 0.12)
            }
            if auth == "Bearer tok-b" && !allowB.get() {
                return .json(200, #"{"code":51203,"msg":"动态二维码已过期"}"#)
            }
            return .json(200, #"{"code":0,"msg":"签到成功"}"#)
        }

        let store = AppStore(vault: vault, historyStore: historyStore, profile: profile, session: session)
        try store.addOrUpdateAccount(makeAccount(id: "acc-a", label: "张三", bearer: "tok-a"))
        try store.addOrUpdateAccount(makeAccount(id: "acc-b", label: "李四", bearer: "tok-b"))

        // 1) 首扫：张三成功、李四失败 -> activeBatchSkippedCount 应为 0
        store.beginScannerSession()
        store.handleContinuousScannerQr("lessonId=8101")
        XCTAssertEqual(store.activeBatchSkippedCount, 0)
        try await waitUntilIdle(store)
        XCTAssertEqual(store.activeBatchSkippedCount, 0)

        // 点击顶部状态胶囊可随时回看本轮已成功自动禁用名单
        store.dismissScannerOverlayNotification()
        XCTAssertNil(store.scannerOverlayNotification)
        store.presentScannerSessionStatusNotification()
        let statusNote = try XCTUnwrap(store.scannerOverlayNotification)
        XCTAssertEqual(statusNote.kind, .info)
        XCTAssertEqual(statusNote.succeededLabels, ["张三"])
        XCTAssertEqual(statusNote.sessionSucceededCount, 1)
        XCTAssertEqual(statusNote.sessionTotalCount, 2)

        // 2) 二次扫码：张三自动跳过（activeBatchSkippedCount == 1），仅李四发起请求并成功
        allowB.set(true)
        store.handleContinuousScannerQr("lessonId=8102")
        XCTAssertEqual(store.activeBatchSkippedCount, 1)
        try await waitUntilIdle(store)
        XCTAssertEqual(store.activeBatchSkippedCount, 0)
        XCTAssertEqual(store.currentTicket?.lessonId, "8102")
        XCTAssertEqual(store.lastBatchTicket?.lessonId, "8102")

        // 3) 全员已成功后扫到新码或误扫无效/登录/非受信任域名码：零请求且绝不覆盖 currentTicket，退出扫码页后首页结果条保持可见
        let reqsBeforeNoOps = requestCount.get()
        store.handleContinuousScannerQr("lessonId=8103")
        XCTAssertEqual(store.currentTicket?.lessonId, "8102", "全员已成功后跳过扫码不得覆盖 currentTicket")
        XCTAssertEqual(store.lastBatchTicket?.lessonId, "8102")
        XCTAssertEqual(requestCount.get(), reqsBeforeNoOps)

        store.handleContinuousScannerQr("random-poster-qr")
        XCTAssertEqual(store.scannerOverlayNotification?.kind, .warning)
        XCTAssertEqual(store.currentTicket?.lessonId, "8102", "本轮已有成功批次时误扫无关码不得覆盖 currentTicket")

        store.handleContinuousScannerQr("https://www.yuketang.cn/v2/web/login?scene=abc")
        XCTAssertEqual(store.scannerOverlayNotification?.kind, .warning)
        XCTAssertEqual(store.currentTicket?.lessonId, "8102")

        store.handleContinuousScannerQr("https://evil.example/api/v3/lesson/checkin?c=x&t=1763900000&s=y")
        XCTAssertEqual(store.scannerOverlayNotification?.kind, .warning)
        XCTAssertEqual(store.currentTicket?.lessonId, "8102")
        XCTAssertEqual(requestCount.get(), reqsBeforeNoOps)

        // 4) 跨会话隔离：会话 1 签到进行中立即关闭并重开会话 2，会话 1 的迟到完成不得污染会话 2 的禁用名单与悬浮通知
        store.endScannerSession()
        slowDelay.set(true)
        store.beginScannerSession()
        store.handleContinuousScannerQr("lessonId=8201")
        XCTAssertTrue(store.isCheckingIn)

        store.endScannerSession()
        store.beginScannerSession()
        try await waitUntilIdle(store)

        XCTAssertTrue(store.isScannerSessionActive)
        XCTAssertTrue(
            store.scannerSessionSucceededAccountIds.isEmpty,
            "旧扫码会话的延迟完成绝不能污染新扫码会话的自动禁用名单"
        )
        XCTAssertNil(
            store.scannerOverlayNotification,
            "旧扫码会话的延迟完成绝不能覆盖新扫码会话的悬浮通知"
        )
    }

    @MainActor
    func testCancelCheckInPersistsPartialHistoryAndSanitizesMessagesAndCheckinId() async throws {
        // 1) SignResult.withoutCredentials 必须同时脱敏 SignResult.message 与 AttemptTrace.message 中的敏感凭据
        let dirtyResult = SignResult(
            accountId: "acc-dirty",
            label: "脱敏校验账号",
            host: "www.yuketang.cn",
            state: .failed,
            strategyId: "APP_SCAN_CHECKIN",
            httpStatus: 401,
            businessCode: 401,
            message: "upstream echoed Authorization: Bearer LEAKED_MSG_BEARER_777 and sessionid=LEAKED_MSG_SID_888",
            elapsedMs: 42,
            attempts: [
                AttemptTrace(
                    strategyId: "APP_SCAN_CHECKIN",
                    method: "POST",
                    url: "https://www.yuketang.cn/api/v3/app/scan?token=LEAKED_URL_TOK_999",
                    httpStatus: 401,
                    businessCode: 401,
                    message: "trace error Bearer LEAKED_TRACE_BEARER_555 csrftoken=LEAKED_TRACE_CSRF_666",
                    elapsedMs: 42,
                    rawSnippet: #"{"sessionid":"LEAKED_RAW_SID_444"}"#
                )
            ]
        )
        let ticketWithCheckin = QrTicket(
            raw: "https://www.yuketang.cn/api/v3/lesson/checkin?lessonId=9010&checkinId=CHK-2026-01",
            kind: .lessonOnly,
            url: "https://www.yuketang.cn/api/v3/lesson/checkin?lessonId=9010&checkinId=CHK-2026-01",
            host: "www.yuketang.cn",
            lessonId: "9010",
            checkinId: "CHK-2026-01"
        )
        let entry = CheckInHistoryEntry.from(ticket: ticketWithCheckin, dryRun: false, results: [dirtyResult])
        XCTAssertEqual(entry.ticketCheckinId, "CHK-2026-01")
        XCTAssertTrue(entry.diagnosticReportText.contains("签到ID: CHK-2026-01"))

        let encoded = try JSONEncoder().encode(entry)
        let encodedText = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        for secret in [
            "LEAKED_MSG_BEARER_777",
            "LEAKED_MSG_SID_888",
            "LEAKED_URL_TOK_999",
            "LEAKED_TRACE_BEARER_555",
            "LEAKED_TRACE_CSRF_666",
            "LEAKED_RAW_SID_444"
        ] {
            XCTAssertFalse(encodedText.contains(secret), "历史序列化结果绝不能泄露凭据: \(secret)")
        }

        // 2) 向后兼容：缺少 ticketCheckinId 的旧版历史 JSON 可正常解码
        let legacyJSON = """
        {
          "id": "legacy-entry-1",
          "createdAtMs": 1763900000000,
          "ticketRaw": "lessonId=1234",
          "ticketKind": "LESSON_ONLY",
          "ticketSummary": "课堂签到 · 1234",
          "ticketHost": "www.yuketang.cn",
          "ticketLessonId": "1234",
          "dryRun": false,
          "results": []
        }
        """
        let decodedLegacy = try JSONDecoder().decode(CheckInHistoryEntry.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decodedLegacy.id, "legacy-entry-1")
        XCTAssertNil(decodedLegacy.ticketCheckinId)

        // 3) 批量签到中途取消时，已完成的账号结果仍保留至持久化历史中
        let profile = try TestBundleResources.loadProtocolProfile()
        let vault = InMemoryAccountVault()
        let historyStore = InMemoryCheckInHistoryStore()
        let fastFinished = LockedBox(false)

        let session = MockNetworkSupport.makeSession { request in
            let auth = MockNetworkSupport.headerValue("Authorization", in: request) ?? ""
            if auth == "Bearer tok-fast" {
                fastFinished.set(true)
                return .json(200, #"{"code":0,"msg":"签到成功"}"#)
            }
            if fastFinished.get() {
                Thread.sleep(forTimeInterval: 0.30)
            } else {
                Thread.sleep(forTimeInterval: 0.20)
            }
            return .json(200, #"{"code":0,"msg":"签到成功"}"#)
        }

        let store = AppStore(vault: vault, historyStore: historyStore, profile: profile, session: session)
        try store.addOrUpdateAccount(makeAccount(id: "acc-fast", label: "先完成账号", bearer: "tok-fast"))
        try store.addOrUpdateAccount(makeAccount(id: "acc-slow", label: "后完成账号", bearer: "tok-slow"))

        store.beginScannerSession()
        store.handleContinuousScannerQr("lessonId=9020")

        var ticks = 0
        while store.checkInCompletedCount < 1 && store.isCheckingIn && ticks < 100 {
            ticks += 1
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(store.checkInCompletedCount, 1)
        XCTAssertTrue(store.isCheckingIn)

        store.cancelCheckIn()
        XCTAssertFalse(store.isCheckingIn)
        XCTAssertEqual(store.history.count, 1, "中途取消时应保留已完成账号的历史记录")
        XCTAssertEqual(store.history.first?.results.map(\.accountId), ["acc-fast"])
        XCTAssertEqual(store.history.first?.succeededCount, 1)
        XCTAssertEqual(store.scannerOverlayNotification?.kind, .info)
        XCTAssertEqual(store.scannerOverlayNotification?.succeededLabels, ["先完成账号"])
    }
}
