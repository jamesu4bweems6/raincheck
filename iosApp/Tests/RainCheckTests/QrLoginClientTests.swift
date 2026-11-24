import Foundation
import XCTest
@testable import RainCheck

final class QrLoginClientTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeClient(
        profile: ProtocolProfile,
        handler: @escaping @Sendable (URLRequest) throws -> MockHTTPResponse
    ) -> QrLoginClient {
        let session = MockNetworkSupport.makeSession(handler: handler)
        return QrLoginClient(session: session, profile: profile)
    }

    // MARK: - Full Happy Path (pre-info -> wait-for-scan -> login -> basic-info)

    func testFullQrLoginHappyPathForwardsPreInfoCookiesAndEnrichesBasicInfo() async throws {
        let profile = try TestBundleResources.loadProtocolProfile()
        let edition = profile.defaultEditionSpec()

        let waitCookieSeen = LockedBox<String?>(nil)
        let waitCsrfSeen = LockedBox<String?>(nil)
        let loginCookieSeen = LockedBox<String?>(nil)
        let loginCsrfSeen = LockedBox<String?>(nil)
        let meAuthSeen = LockedBox<String?>(nil)
        let meCookieSeen = LockedBox<String?>(nil)

        let client = makeClient(profile: profile) { request in
            let path = request.url?.path ?? ""
            switch path {
            case "/api/v3/user/login/pre-info":
                return .json(
                    200,
                    #"{"code":0,"data":{"qrContent":"https://open.weixin.qq.com/connect/qrconnect?state=lt-happy","token":"lt-happy"}}"#,
                    headers: ["Set-Cookie": "csrftoken=pre-csrf-happy; Path=/"]
                )
            case "/api/v3/user/login/wait-for-scan":
                waitCookieSeen.set(MockNetworkSupport.headerValue("Cookie", in: request))
                waitCsrfSeen.set(MockNetworkSupport.headerValue("X-CSRFToken", in: request))
                return .json(200, #"{"code":0,"msg":"已扫码，等待确认","data":{"scanned":true}}"#)
            case "/api/v3/user/login":
                loginCookieSeen.set(MockNetworkSupport.headerValue("Cookie", in: request))
                loginCsrfSeen.set(MockNetworkSupport.headerValue("X-CSRFToken", in: request))
                return .json(
                    200,
                    #"{"code":0,"msg":"登录成功","data":{"ok":true}}"#,
                    headers: [
                        "set-auth": "Bearer login-tok-happy",
                        "Set-Cookie": "sessionid=login-sid-happy; Path=/; HttpOnly"
                    ]
                )
            case "/api/v3/user/basic-info":
                meAuthSeen.set(MockNetworkSupport.headerValue("Authorization", in: request))
                meCookieSeen.set(MockNetworkSupport.headerValue("Cookie", in: request))
                return .json(
                    200,
                    #"{"code":0,"data":{"id":"u888","name":"李同学"}}"#,
                    headers: ["set-auth": "Bearer refreshed-me-tok"]
                )
            default:
                return .json(404, #"{"code":40400}"#)
            }
        }

        // 1. pre-info
        let session = try await client.startSession(edition: edition)
        XCTAssertEqual(session.loginToken, "lt-happy")
        XCTAssertEqual(session.qrContent, "https://open.weixin.qq.com/connect/qrconnect?state=lt-happy")
        XCTAssertEqual(session.cookies["csrftoken"], "pre-csrf-happy")

        // 2. wait-for-scan（验证 pre-info 下发的 Cookie 与 X-CSRFToken 透传）
        let waitOutcome = await client.waitForScan(session: session)
        XCTAssertEqual(waitOutcome, .scanned)
        XCTAssertTrue(waitCookieSeen.get()?.contains("csrftoken=pre-csrf-happy") == true)
        XCTAssertEqual(waitCsrfSeen.get(), "pre-csrf-happy")

        // 3. login -> basic-info（验证 Cookie 透传、刷新 token 吸收与资料回填）
        let pollOutcome = await client.pollLogin(session: session)
        XCTAssertTrue(loginCookieSeen.get()?.contains("csrftoken=pre-csrf-happy") == true)
        XCTAssertEqual(loginCsrfSeen.get(), "pre-csrf-happy")
        XCTAssertEqual(meAuthSeen.get(), "Bearer login-tok-happy")
        XCTAssertTrue(meCookieSeen.get()?.contains("sessionid=login-sid-happy") == true)

        guard case .authenticated(let account) = pollOutcome else {
            XCTFail("预期 pollLogin 返回 .authenticated，实际为 \(pollOutcome)")
            return
        }
        XCTAssertEqual(account.bearer, "refreshed-me-tok", "basic-info 的 set-auth 必须被吸收")
        XCTAssertEqual(account.sessionId, "login-sid-happy")
        XCTAssertEqual(account.csrfToken, "pre-csrf-happy", "pre-info 的 csrftoken 应延续到最终账号")
        XCTAssertEqual(account.label, "李同学")
        XCTAssertEqual(account.userId, "u888")
        XCTAssertGreaterThan(account.createdAt, 0)
        XCTAssertNotNil(account.lastOkAt)
    }

    // MARK: - SCANNED + NEED_CODE Verification & Retry

    func testScannedAndNeedCodeVerificationWithRetryAndVerifyTokenPersistence() async throws {
        let profile = try TestBundleResources.loadProtocolProfile()
        let edition = profile.defaultEditionSpec()

        let waitRound = LockedBox(0)
        let codeTokensSeen = LockedBox<[String]>([])
        let codeRequestsCount = LockedBox(0)

        let client = makeClient(profile: profile) { request in
            let path = request.url?.path ?? ""
            switch path {
            case "/api/v3/user/login/pre-info":
                return .json(
                    200,
                    #"{"code":0,"data":{"qrContent":"https://open.weixin.qq.com/connect/qrconnect?state=lt-code","token":"lt-code"}}"#,
                    headers: ["Set-Cookie": "csrftoken=csrf-code-1; Path=/"]
                )
            case "/api/v3/user/login/wait-for-scan":
                let round = waitRound.withLock { current -> Int in
                    current += 1
                    return current
                }
                switch round {
                case 1:
                    // data.token 为 null 时绝不误判为 needsCode
                    return .json(200, #"{"code":40001,"msg":"等待扫码","data":{"token":null}}"#)
                case 2:
                    return .json(200, #"{"code":0,"msg":"已扫码，等待确认","data":{"scanned":true}}"#)
                default:
                    return .json(200, #"{"code":40010,"msg":"需要验证码","data":{"verify_token":"vt-99"}}"#)
                }
            case "/api/v3/user/login/login-with-code":
                codeRequestsCount.withLock { $0 += 1 }
                let json = MockNetworkSupport.requestBodyJSON(from: request)
                let token = json?["token"]?.stringValue ?? ""
                let code = json?["code"]?.stringValue ?? ""
                codeTokensSeen.withLock { $0.append(token) }

                if code == "0000" {
                    return .json(200, #"{"code":40004,"msg":"验证码错误","data":{"verify_token":"vt-99"}}"#)
                }
                return .json(
                    200,
                    #"{"code":0,"msg":"登录成功","data":{"verified":true}}"#,
                    headers: [
                        "set-auth": "Bearer code-login-tok",
                        "Set-Cookie": "sessionid=code-login-sid; Path=/; HttpOnly"
                    ]
                )
            case "/api/v3/user/basic-info":
                return .json(200, #"{"code":0,"data":{"id":"u999","name":"王同学"}}"#)
            default:
                return .json(404, #"{"code":40400}"#)
            }
        }

        let session = try await client.startSession(edition: edition)

        // Round 1: pending (token: null 不误判)
        let r1 = await client.waitForScan(session: session)
        XCTAssertEqual(r1, .pending)

        // Round 2: scanned
        let r2 = await client.waitForScan(session: session)
        XCTAssertEqual(r2, .scanned)

        // Round 3: needsCode 并缓存 verify_token = vt-99
        let r3 = await client.waitForScan(session: session)
        guard case .needsCode = r3 else {
            XCTFail("预期进入 .needsCode，实际为 \(r3)")
            return
        }

        // 格式不合法验证码：本地拦截，零网络请求，保持 .needsCode
        let badFormat = await client.submitCode(session: session, code: "12a")
        guard case .needsCode = badFormat else {
            XCTFail("非法验证码格式应返回 .needsCode，实际为 \(badFormat)")
            return
        }
        XCTAssertEqual(codeRequestsCount.get(), 0)

        // 错误 4 位验证码：提交 vt-99，返回 .needsCode 便于用户重试
        let wrongCode = await client.submitCode(session: session, code: "0000")
        XCTAssertEqual(wrongCode, .needsCode("验证码错误"))

        // 正确 4 位验证码：继续携带 vt-99，登录成功并回填用户信息
        let rightCode = await client.submitCode(session: session, code: "1234")
        XCTAssertEqual(codeTokensSeen.get(), ["vt-99", "vt-99"], "两次提交验证码都应携带缓存的 verify_token")

        guard case .authenticated(let account) = rightCode else {
            XCTFail("预期验证码通过后返回 .authenticated，实际为 \(rightCode)")
            return
        }
        XCTAssertEqual(account.bearer, "code-login-tok")
        XCTAssertEqual(account.sessionId, "code-login-sid")
        XCTAssertEqual(account.csrfToken, "csrf-code-1")
        XCTAssertEqual(account.label, "王同学")
        XCTAssertEqual(account.userId, "u999")
    }

    // MARK: - Empty Credential Rejection, Expiry Precedence & Error Handling

    func testEmptyCredentialRejectionAndExpiryPrecedence() async throws {
        let profile = try TestBundleResources.loadProtocolProfile()
        let edition = profile.defaultEditionSpec()

        // 1) finalizeAccount 严格拒绝空凭据或仅有 csrftoken 的情况，且不发起网络请求
        let finalizeCalls = LockedBox(0)
        let rejectClient = makeClient(profile: profile) { _ in
            finalizeCalls.withLock { $0 += 1 }
            return .json(200, #"{"code":0,"data":{"id":"u1","name":"不应该成功"}}"#)
        }
        let nilEmpty = await rejectClient.finalizeAccount(edition: edition, bearer: nil, cookies: [:])
        let nilCsrfOnly = await rejectClient.finalizeAccount(
            edition: edition,
            bearer: "   ",
            cookies: ["csrftoken": "only-csrf-no-session"]
        )
        XCTAssertNil(nilEmpty)
        XCTAssertNil(nilCsrfOnly)
        XCTAssertEqual(finalizeCalls.get(), 0)

        // 2) pollLogin 返回 code=0 但没有任何 set-auth / Set-Cookie 时，绝不伪造 .authenticated
        let noCredClient = makeClient(profile: profile) { request in
            if request.url?.path == "/api/v3/user/login" {
                return .json(200, #"{"code":0,"msg":"ok","data":{"id":"u1"}}"#)
            }
            return .json(404, #"{}"#)
        }
        let sessionNoCred = QrLoginSession(edition: edition, loginToken: "lt-nocred", qrContent: "https://x")
        let noCredOutcome = await noCredClient.pollLogin(session: sessionNoCred)
        guard case .failed = noCredOutcome else {
            XCTFail("空凭据响应绝不能返回 .authenticated，实际为 \(noCredOutcome)")
            return
        }

        // 3) 过期判定优先级高于 verify_token
        let expiredClient = makeClient(profile: profile) { _ in
            .json(200, #"{"code":50000,"msg":"二维码已失效","data":{"verify_token":"stale-vt"}}"#)
        }
        let sessionExp = QrLoginSession(edition: edition, loginToken: "lt-exp", qrContent: "https://x")
        let expOutcome = await expiredClient.waitForScan(session: sessionExp)
        guard case .expired = expOutcome else {
            XCTFail("预期返回 .expired，实际为 \(expOutcome)")
            return
        }

        // 4) startSession 遇 404/500 或 data.token == null 报 .failed 而非 .expired
        let client404 = makeClient(profile: profile) { _ in
            .json(404, #"{"code":40400,"msg":"not found"}"#)
        }
        do {
            _ = try await client404.startSession(edition: edition)
            XCTFail("HTTP 404 应抛出 QrLoginError.failed")
        } catch let error as QrLoginError {
            guard case .failed = error else {
                XCTFail("HTTP 404 不应判为 expired，实际为 \(error)")
                return
            }
        }

        let clientNullToken = makeClient(profile: profile) { _ in
            .json(200, #"{"code":0,"data":{"qrContent":"https://x","token":null}}"#)
        }
        do {
            _ = try await clientNullToken.startSession(edition: edition)
            XCTFail("data.token 为 null 应抛出 QrLoginError.failed")
        } catch let error as QrLoginError {
            guard case .failed = error else {
                XCTFail("data.token 为 null 应返回 .failed，实际为 \(error)")
                return
            }
        }
    }

    // MARK: - Degraded basic-info Preserves Valid Session

    func testDegradedBasicInfoPreservesValidSession() async throws {
        let profile = try TestBundleResources.loadProtocolProfile()
        let edition = profile.defaultEditionSpec()

        let client = makeClient(profile: profile) { request in
            switch request.url?.path ?? "" {
            case "/api/v3/user/login/pre-info":
                return .json(
                    200,
                    #"{"code":0,"data":{"qrContent":"https://open.weixin.qq.com/connect/qrconnect?state=lt-deg","token":"lt-deg"}}"#,
                    headers: ["Set-Cookie": "csrftoken=csrf-deg-1; Path=/"]
                )
            case "/api/v3/user/login":
                return .json(
                    200,
                    #"{"code":0,"msg":"登录成功"}"#,
                    headers: [
                        "set-auth": "Bearer valid-token-despite-me-503",
                        "Set-Cookie": "sessionid=valid-sid-despite-me-503; Path=/; HttpOnly"
                    ]
                )
            case "/api/v3/user/basic-info":
                return .json(503, #"{"code":50300,"msg":"用户信息服务暂时不可用"}"#)
            default:
                return .json(404, #"{"code":40400}"#)
            }
        }

        let session = try await client.startSession(edition: edition)
        let outcome = await client.pollLogin(session: session)

        guard case .authenticated(let account) = outcome else {
            XCTFail("basic-info 临时降级时仍须保留有效会话，实际为 \(outcome)")
            return
        }
        XCTAssertEqual(account.bearer, "valid-token-despite-me-503")
        XCTAssertEqual(account.sessionId, "valid-sid-despite-me-503")
        XCTAssertEqual(account.csrfToken, "csrf-deg-1")
        XCTAssertEqual(account.host, edition.host)
        XCTAssertEqual(account.scheme, edition.scheme)
        XCTAssertTrue(account.hasCredential)
        XCTAssertGreaterThan(account.createdAt, 0)
        XCTAssertNil(account.lastOkAt, "basic-info 降级未验证通过时不强行刷新 lastOkAt")
    }
}
