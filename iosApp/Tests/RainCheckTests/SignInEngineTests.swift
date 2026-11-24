//
//  SignInEngineTests.swift
//  RainCheckTests
//
//  使用自定义 MockURLProtocol 全面验证：
//   - 策略链真实回退（DYN_TICKET_14 -> DYN_TICKET_5）；
//   - `QR_URL_POST`/`QR_URL_GET` 恶意域名拦截（向 evil.example 零请求）；
//   - `ALREADY` 优先于 `okCodes`（`code==0 && msg=="已签到"` -> `ALREADY`，`msg=="签到成功"` -> `SUCCESS`）；
//   - `dryRun = true` 严格零网络请求（跳过 `discover()`，返回 `DRY_RUN`）；
//   - HTTP 200 业务鉴权失败判 `AUTH_REQUIRED`；
//   - `JSONAssist.int(false) == nil`（排除 `CFBoolean`）且 Dict/Array 不转调试串；
//   - `errcode`/`errmsg` 兼容、5xx+过期立即中止重试、重试耗尽返回 `ERROR`；
//   - `set-auth` 优先于 `authorization`、忽略过期/空值 `Set-Cookie`、会话刷新即时传给后续策略；
//   - 导出 JSON (`SignExport`) 严格零凭据泄露；
//   - `AccountVaultStore` 元信息零凭据落盘与回写不复活已删账号。
//

import Foundation
import XCTest
@testable import RainCheck

private final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class SignInEngineTests: XCTestCase {
    func testStrategyFallbackFromTicket14ToTicket5() async throws {
        let profile = try TestFixtures.loadProtocolProfile()
        let routerId = UUID().uuidString
        defer { MockTransportBox.shared.unregister(id: routerId) }

        let api = TestFixtures.makeMockApi(profile: profile, routerId: routerId) { req in
            if req.body.contains("\"source\":14") {
                return MockHTTPResponse(jsonText: #"{"code":4001,"msg":"当前校区不支持桌面来源"}"#)
            }
            if req.body.contains("\"source\":5") {
                return MockHTTPResponse(jsonText: #"{"code":0,"msg":"签到成功"}"#)
            }
            return MockHTTPResponse(statusCode: 400, jsonText: #"{"code":4000,"msg":"unexpected"}"#)
        }
        let engine = SignInEngine(api: api, profile: profile)
        let ticket = QrParser.parse(
            "https://www.yuketang.cn/api/v3/lesson/checkin?c=c123&t=1763900000&s=sig1&v=2&lessonId=10086",
            profile: profile
        )

        let result = await engine.signIn(
            account: TestFixtures.sampleAccount(),
            ticket: ticket,
            options: SignOptions(maxAttemptsPerStrategy: 1, baseBackoffMs: 0)
        )

        XCTAssertEqual(result.state, .SUCCESS)
        XCTAssertEqual(result.strategy, "DYN_TICKET_5")
        XCTAssertEqual(result.attempts.count, 2)
        XCTAssertEqual(result.attempts[0].strategy, "DYN_TICKET_14")
        XCTAssertEqual(result.attempts[1].strategy, "DYN_TICKET_5")
    }

    func testMaliciousExternalDomainBlockedInQrUrlStrategiesWithZeroRequests() async throws {
        let profile = try TestFixtures.loadProtocolProfile()
        let routerId = UUID().uuidString
        defer { MockTransportBox.shared.unregister(id: routerId) }

        let api = TestFixtures.makeMockApi(profile: profile, routerId: routerId) { _ in
            return MockHTTPResponse(jsonText: #"{"code":4002,"msg":"策略不匹配"}"#)
        }
        let engine = SignInEngine(api: api, profile: profile)
        let evilTicket = QrParser.parse(
            "https://evil.example/steal?c=bad&t=1763900000&s=evil&lessonId=999",
            profile: profile
        )

        let result = await engine.signIn(
            account: TestFixtures.sampleAccount(),
            ticket: evilTicket,
            options: SignOptions(maxAttemptsPerStrategy: 1, baseBackoffMs: 0)
        )

        let captured = MockTransportBox.shared.requests(for: routerId)
        XCTAssertFalse(captured.contains { $0.url.contains("evil.example") }, "严禁向恶意第三方域名发出任何请求")
        XCTAssertTrue(
            result.attempts.contains { $0.strategy == "QR_URL_POST" && ($0.message?.contains("安全拦截") == true) },
            "QR_URL_POST 应记录安全拦截原因"
        )
        XCTAssertTrue(
            result.attempts.contains { $0.strategy == "QR_URL_GET" && ($0.message?.contains("安全拦截") == true) },
            "QR_URL_GET 应记录安全拦截原因"
        )
    }

    func testAlreadyTakesPrecedenceOverOkCodeWhileSuccessStaysSuccess() async throws {
        let profile = try TestFixtures.loadProtocolProfile()
        let routerId = UUID().uuidString
        defer { MockTransportBox.shared.unregister(id: routerId) }

        let calls = AtomicCounter()
        let api = TestFixtures.makeMockApi(profile: profile, routerId: routerId) { _ in
            let n = calls.increment()
            if n == 1 {
                return MockHTTPResponse(jsonText: #"{"code":0,"msg":"已签到"}"#)
            }
            return MockHTTPResponse(jsonText: #"{"code":0,"msg":"签到成功"}"#)
        }
        let engine = SignInEngine(api: api, profile: profile)
        let ticket = QrParser.parse("1529274209982060032", profile: profile)

        let first = await engine.signIn(
            account: TestFixtures.sampleAccount(),
            ticket: ticket,
            options: SignOptions(maxAttemptsPerStrategy: 1, baseBackoffMs: 0)
        )
        XCTAssertEqual(first.state, .ALREADY)
        XCTAssertTrue(first.ok)

        let second = await engine.signIn(
            account: TestFixtures.sampleAccount(),
            ticket: ticket,
            options: SignOptions(maxAttemptsPerStrategy: 1, baseBackoffMs: 0)
        )
        XCTAssertEqual(second.state, .SUCCESS)
        XCTAssertTrue(second.ok)
    }

    func testDryRunMakesZeroNetworkRequestsEvenWithoutLessonId() async throws {
        let profile = try TestFixtures.loadProtocolProfile()
        let routerId = UUID().uuidString
        defer { MockTransportBox.shared.unregister(id: routerId) }

        let api = TestFixtures.makeMockApi(profile: profile, routerId: routerId) { _ in
            XCTFail("dryRun 模式下绝不应发出任何网络请求（包括 activeLesson discover）")
            return MockHTTPResponse(jsonText: #"{"code":0}"#)
        }
        let engine = SignInEngine(api: api, profile: profile)
        // 无 lessonId 的裸动态码，若不跳过 discover 必然发起 activeLesson 请求
        let ticket = QrParser.parse("c=abc123&t=1763900000&s=deadbeef&v=2", profile: profile)

        let result = await engine.signIn(
            account: TestFixtures.sampleAccount(),
            ticket: ticket,
            options: SignOptions(dryRun: true)
        )

        XCTAssertEqual(result.state, .DRY_RUN)
        XCTAssertNil(result.refreshedAccount)
        XCTAssertFalse(result.attempts.isEmpty)
        XCTAssertEqual(MockTransportBox.shared.requests(for: routerId).count, 0)
    }

    func testHttp200AuthFailureClassifiedAsAuthRequired() async throws {
        let profile = try TestFixtures.loadProtocolProfile()
        let routerId = UUID().uuidString
        defer { MockTransportBox.shared.unregister(id: routerId) }

        let api = TestFixtures.makeMockApi(profile: profile, routerId: routerId) { _ in
            MockHTTPResponse(statusCode: 200, jsonText: #"{"code":1001,"msg":"未授权，请重新登录"}"#)
        }
        let engine = SignInEngine(api: api, profile: profile)
        let ticket = QrParser.parse("1529274209982060032", profile: profile)

        let result = await engine.signIn(
            account: TestFixtures.sampleAccount(),
            ticket: ticket,
            options: SignOptions(maxAttemptsPerStrategy: 2, baseBackoffMs: 0)
        )

        XCTAssertEqual(result.state, .AUTH_REQUIRED)
        XCTAssertEqual(result.attempts.count, 1, "鉴权失败应立即中止后续策略")
    }

    func testJsonAssistExcludesCFBooleanAndContainers() async throws {
        XCTAssertNil(JSONAssist.int(false as Any), "CFBoolean false 绝不能被当作 Int 0")
        XCTAssertNil(JSONAssist.int(true as Any), "CFBoolean true 绝不能被当作 Int 1")
        XCTAssertEqual(JSONAssist.int(0 as Any), 0)
        XCTAssertEqual(JSONAssist.int("42" as Any), 42)
        XCTAssertNil(JSONAssist.string(["nested": 1] as Any), "Dictionary 绝不能转为调试字符串")
        XCTAssertNil(JSONAssist.string([1, 2, 3] as Any), "Array 绝不能转为调试字符串")
        XCTAssertNil(JSONAssist.string(NSNull()))

        // 端到端验证：服务端返回 {"code": false} 不得判为签到成功
        let profile = try TestFixtures.loadProtocolProfile()
        let routerId = UUID().uuidString
        defer { MockTransportBox.shared.unregister(id: routerId) }

        let api = TestFixtures.makeMockApi(profile: profile, routerId: routerId) { _ in
            MockHTTPResponse(statusCode: 200, jsonText: #"{"code":false,"msg":"invalid"}"#)
        }
        let engine = SignInEngine(api: api, profile: profile)
        let ticket = QrParser.parse("1529274209982060032", profile: profile)

        let result = await engine.signIn(
            account: TestFixtures.sampleAccount(),
            ticket: ticket,
            options: SignOptions(maxAttemptsPerStrategy: 1, baseBackoffMs: 0)
        )
        XCTAssertEqual(result.state, .FAILED)
    }

    func testErrcodeAndErrmsgCompatibilityAndExpired5xxAbortsRetry() async throws {
        let profile = try TestFixtures.loadProtocolProfile()
        let routerId = UUID().uuidString
        defer { MockTransportBox.shared.unregister(id: routerId) }

        let calls = AtomicCounter()
        let api = TestFixtures.makeMockApi(profile: profile, routerId: routerId) { _ in
            let n = calls.increment()
            if n == 1 {
                return MockHTTPResponse(statusCode: 200, jsonText: #"{"errcode":0,"errmsg":"已经签到过了"}"#)
            }
            return MockHTTPResponse(statusCode: 500, jsonText: #"{"errcode":5001,"errmsg":"二维码已过期"}"#)
        }
        let engine = SignInEngine(api: api, profile: profile)
        let ticket = QrParser.parse("1529274209982060032", profile: profile)

        let already = await engine.signIn(
            account: TestFixtures.sampleAccount(),
            ticket: ticket,
            options: SignOptions(maxAttemptsPerStrategy: 3, baseBackoffMs: 0)
        )
        XCTAssertEqual(already.state, .ALREADY)

        let expired = await engine.signIn(
            account: TestFixtures.sampleAccount(),
            ticket: ticket,
            options: SignOptions(maxAttemptsPerStrategy: 3, baseBackoffMs: 0)
        )
        XCTAssertEqual(expired.state, .TICKET_EXPIRED)
        XCTAssertEqual(expired.attempts.count, 1, "5xx 携带过期关键字应立即中止重试")
    }

    func testSessionRefreshFlowsToNextStrategyAndExportJsonHasZeroCredentials() async throws {
        let profile = try TestFixtures.loadProtocolProfile()
        let routerId = UUID().uuidString
        defer { MockTransportBox.shared.unregister(id: routerId) }

        let newBearer = "tok_fresh_rotated_secret_xyz123456"
        let newSession = "sid_fresh_rotated_secret_uvw654321"
        let newCsrf = "csrf_fresh_rotated_secret_987654"

        let api = TestFixtures.makeMockApi(profile: profile, routerId: routerId) { req in
            if req.body.contains("\"source\":14") {
                return MockHTTPResponse(
                    statusCode: 200,
                    headers: [
                        "Content-Type": "application/json",
                        "set-auth": "Bearer \(newBearer)",
                        "authorization": "Bearer ignored_lower_priority_token",
                        "Set-Cookie": "sessionid=\(newSession); Path=/; HttpOnly, csrftoken=\(newCsrf); Path=/, expired=gone; Expires=Thu, 01 Jan 1970 00:00:00 GMT"
                    ],
                    jsonText: #"{"code":4001,"msg":"请切换小程序来源"}"#
                )
            }
            return MockHTTPResponse(jsonText: #"{"code":0,"msg":"签到成功"}"#)
        }
        let engine = SignInEngine(api: api, profile: profile)
        let account = TestFixtures.sampleAccount()
        let ticket = QrParser.parse(
            "https://www.yuketang.cn/api/v3/lesson/checkin?c=c1&t=1763900000&s=s1&lessonId=2026",
            profile: profile
        )

        let result = await engine.signIn(
            account: account,
            ticket: ticket,
            options: SignOptions(maxAttemptsPerStrategy: 1, baseBackoffMs: 0)
        )

        XCTAssertEqual(result.state, .SUCCESS)
        XCTAssertEqual(result.refreshedAccount?.bearer, newBearer, "set-auth 应优先于 authorization")
        XCTAssertEqual(result.refreshedAccount?.sessionId, newSession)
        XCTAssertEqual(result.refreshedAccount?.csrfToken, newCsrf)

        // 验证第二条策略立即使用了刷新后的新凭据
        let requests = MockTransportBox.shared.requests(for: routerId)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].headers["Authorization"], "Bearer \(newBearer)")
        XCTAssertTrue(requests[1].headers["Cookie"]?.contains("sessionid=\(newSession)") == true)
        XCTAssertEqual(requests[1].headers["X-CSRFToken"], newCsrf)

        // Critical 断言：导出 JSON 绝对不能包含任何凭据或 refreshedAccount 字段
        let export = SignExport(
            exportedAt: TimeUtil.nowMillis(),
            profileName: profile.name,
            profileVersion: profile.version,
            ticket: ticket,
            results: [result]
        )
        let encoded = try JSONEncoder().encode(export)
        let jsonText = String(decoding: encoded, as: UTF8.self)

        XCTAssertFalse(jsonText.contains("refreshedAccount"), "SignResult 绝不能序列化 refreshedAccount")
        XCTAssertFalse(jsonText.contains(newBearer), "导出 JSON 不得泄露新 Bearer Token")
        XCTAssertFalse(jsonText.contains(newSession), "导出 JSON 不得泄露新 sessionId")
        XCTAssertFalse(jsonText.contains(newCsrf), "导出 JSON 不得泄露新 csrfToken")
        XCTAssertFalse(jsonText.contains(account.bearer ?? ""), "导出 JSON 不得泄露旧 Bearer Token")
        XCTAssertFalse(jsonText.contains(account.sessionId ?? ""), "导出 JSON 不得泄露旧 sessionId")
    }

    func testVaultStoreExcludesSecretsFromDiskAndNeverResurrectsDeletedAccount() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("raincheck-vault-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let metaURL = tempDir.appendingPathComponent("accounts_meta.json")
        let secrets = InMemorySecretStore()
        let vault = AccountVaultStore(metadataURL: metaURL, secrets: secrets)

        let accA = TestFixtures.sampleAccount(id: "a", label: "账号A")
        let accB = TestFixtures.sampleAccount(id: "b", label: "账号B")
        vault.save([accA, accB])

        // 磁盘元信息文件绝对不包含明文凭据
        let diskText = try String(contentsOf: metaURL, encoding: .utf8)
        XCTAssertFalse(diskText.contains(accA.bearer ?? ""))
        XCTAssertFalse(diskText.contains(accA.sessionId ?? ""))
        XCTAssertFalse(diskText.contains(accA.csrfToken ?? ""))

        // 重新加载可从密钥库完整还原
        let loaded = vault.load()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.first(where: { $0.id == "a" })?.bearer, accA.bearer)

        // 模拟签到期间用户删除了 accB，且修改了 accA 的标签与停用状态
        var editedA = accA
        editedA.label = "用户新命名A"
        editedA.enabled = false
        let currentPool = [editedA]

        var refreshedA = accA
        refreshedA.bearer = "rotated_bearer_a_1234567890"
        var refreshedB = accB
        refreshedB.bearer = "rotated_bearer_b_1234567890"

        let merged = AccountVaultStore.applyingRefreshedCredentials(to: currentPool, updates: [refreshedA, refreshedB])
        XCTAssertEqual(merged.appliedCount, 1)
        XCTAssertEqual(merged.accounts.count, 1, "绝不能复活已删除的 accB")
        XCTAssertEqual(merged.accounts[0].id, "a")
        XCTAssertEqual(merged.accounts[0].label, "用户新命名A", "绝不能覆盖用户修改的 label")
        XCTAssertFalse(merged.accounts[0].enabled, "绝不能覆盖用户修改的 enabled")
        XCTAssertEqual(merged.accounts[0].bearer, "rotated_bearer_a_1234567890")
    }
}
