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
        XCTAssertTrue(single.state.isSuccessLike)
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
}
