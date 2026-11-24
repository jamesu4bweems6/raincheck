//
//  LoginServiceTests.swift
//  RainCheckTests
//
//  覆盖完整扫码登录状态机（pre-info Cookie 透传、SCANNED、NEED_CODE 错码重试、
//  finishLogin 无凭据拦截、verify 失败保留会话、404 报 ERROR）。
//

import Foundation
import XCTest
@testable import RainCheck

private final class StepCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var step: Int = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        step += 1
        return step
    }
}

final class LoginServiceTests: XCTestCase {
    func testFullLoginFlowWithPreInfoCookieScannedAndVerify() async throws {
        let profile = try TestFixtures.loadProtocolProfile()
        let routerId = UUID().uuidString
        defer { MockTransportBox.shared.unregister(id: routerId) }

        let pollStep = StepCounter()
        let api = TestFixtures.makeMockApi(profile: profile, routerId: routerId) { req in
            if req.url.contains("/api/v3/user/login/pre-info") {
                return MockHTTPResponse(
                    headers: [
                        "Content-Type": "application/json",
                        "Set-Cookie": "csrftoken=pre_csrf_001; Path=/"
                    ],
                    jsonText: #"{"code":0,"data":{"qrContent":"https://open.weixin.qq.com/connect/qrconnect?state=login","token":"ltok_001"}}"#
                )
            }
            if req.url.contains("/api/v3/user/login/wait-for-scan") {
                let n = pollStep.next()
                if n == 1 {
                    return MockHTTPResponse(jsonText: #"{"code":2001,"msg":"已扫码，请确认","data":{"scanned":true}}"#)
                }
                return MockHTTPResponse(jsonText: #"{"code":0,"msg":"已确认"}"#)
            }
            if req.url.hasSuffix("/api/v3/user/login") {
                if req.headers["X-CSRFToken"] != "pre_csrf_001" {
                    return MockHTTPResponse(statusCode: 403, jsonText: #"{"code":403,"msg":"missing pre csrf"}"#)
                }
                // 第一次轮询尚未确认，第二次返回会话
                let requests = MockTransportBox.shared.requests(for: routerId)
                let loginCalls = requests.filter { $0.url.hasSuffix("/api/v3/user/login") }.count
                if loginCalls == 1 {
                    return MockHTTPResponse(jsonText: #"{"code":2002,"msg":"等待确认"}"#)
                }
                return MockHTTPResponse(
                    headers: [
                        "Content-Type": "application/json",
                        "set-auth": "Bearer login_jwt_token_abc123456"
                    ],
                    jsonText: #"{"code":0,"msg":"ok"}"#
                )
            }
            if req.url.contains("/api/v3/user/basic-info") {
                return MockHTTPResponse(
                    headers: [
                        "Content-Type": "application/json",
                        "Set-Cookie": "sessionid=sid_from_me_999; Path=/"
                    ],
                    jsonText: #"{"code":0,"data":{"id":"42001","name":"清华小雨"}}"#
                )
            }
            return MockHTTPResponse(statusCode: 404, jsonText: #"{"code":404}"#)
        }

        let service = LoginService(api: api, profile: profile)
        let started = await service.start(edition: Edition.WWW)
        XCTAssertEqual(started.state, .PENDING)
        XCTAssertEqual(started.loginToken, "ltok_001")

        let firstPoll = await service.poll(edition: Edition.WWW, loginToken: "ltok_001")
        XCTAssertEqual(firstPoll.state, .SCANNED)

        let secondPoll = await service.poll(edition: Edition.WWW, loginToken: "ltok_001")
        XCTAssertEqual(secondPoll.state, .AUTHORIZED)
        XCTAssertEqual(secondPoll.account?.label, "清华小雨")
        XCTAssertEqual(secondPoll.account?.userId, "42001")
        XCTAssertEqual(secondPoll.account?.bearer, "login_jwt_token_abc123456")
        XCTAssertEqual(secondPoll.account?.sessionId, "sid_from_me_999", "verify 应吸收 me.auth 回填")
    }

    func testNeedCodeWrongCodeRetainsNeedCodeAndValidCodeSucceeds() async throws {
        let profile = try TestFixtures.loadProtocolProfile()
        let routerId = UUID().uuidString
        defer { MockTransportBox.shared.unregister(id: routerId) }

        let api = TestFixtures.makeMockApi(profile: profile, routerId: routerId) { req in
            if req.url.contains("/wait-for-scan") {
                return MockHTTPResponse(jsonText: #"{"code":3001,"msg":"需要验证码","data":{"verify_token":"vtok_777","need_code":true}}"#)
            }
            if req.url.contains("/login-with-code") {
                if req.body.contains("\"code\":\"0000\"") {
                    return MockHTTPResponse(jsonText: #"{"code":3002,"msg":"验证码错误"}"#)
                }
                return MockHTTPResponse(
                    headers: [
                        "Content-Type": "application/json",
                        "set-auth": "Bearer code_verified_token_1234567"
                    ],
                    jsonText: #"{"code":0,"msg":"ok"}"#
                )
            }
            if req.url.contains("/basic-info") {
                return MockHTTPResponse(jsonText: #"{"code":0,"data":{"id":"888","name":"验证码用户"}}"#)
            }
            return MockHTTPResponse(statusCode: 404, jsonText: "{}")
        }

        let service = LoginService(api: api, profile: profile)
        let needCode = await service.poll(edition: Edition.PRO, loginToken: "ltok_code")
        XCTAssertEqual(needCode.state, .NEED_CODE)
        XCTAssertEqual(needCode.loginToken, "vtok_777")

        let wrongFormat = await service.submitCode(edition: Edition.PRO, loginToken: "vtok_777", code: "12")
        XCTAssertEqual(wrongFormat.state, .NEED_CODE)

        let wrongCode = await service.submitCode(edition: Edition.PRO, loginToken: "vtok_777", code: "0000")
        XCTAssertEqual(wrongCode.state, .NEED_CODE, "错码应停留在 NEED_CODE 便于重试")
        XCTAssertEqual(wrongCode.loginToken, "vtok_777")

        let ok = await service.submitCode(edition: Edition.PRO, loginToken: "vtok_777", code: "1234")
        XCTAssertEqual(ok.state, .AUTHORIZED)
        XCTAssertEqual(ok.account?.label, "验证码用户")
    }

    func testFinishLoginRejectsEmptyCredentialsAndPreservesSessionWhenVerifyFails() async throws {
        let profile = try TestFixtures.loadProtocolProfile()
        let routerId = UUID().uuidString
        defer { MockTransportBox.shared.unregister(id: routerId) }

        let loginCalls = StepCounter()
        let api = TestFixtures.makeMockApi(profile: profile, routerId: routerId) { req in
            if req.url.contains("/wait-for-scan") {
                return MockHTTPResponse(jsonText: #"{"code":0}"#)
            }
            if req.url.hasSuffix("/api/v3/user/login") {
                let n = loginCalls.next()
                if n == 1 {
                    // 第一次：code==0 但服务端未下发任何会话头 -> 绝不能伪造 AUTHORIZED
                    return MockHTTPResponse(jsonText: #"{"code":0,"msg":"ok"}"#)
                }
                // 第二次：下发了有效 set-auth，但 basic-info 暂时返回 503 -> 仍保留会话入池
                return MockHTTPResponse(
                    headers: [
                        "Content-Type": "application/json",
                        "set-auth": "Bearer fallback_keep_session_token"
                    ],
                    jsonText: #"{"code":0,"msg":"ok"}"#
                )
            }
            if req.url.contains("/basic-info") {
                return MockHTTPResponse(statusCode: 503, jsonText: #"{"code":503,"msg":"busy"}"#)
            }
            return MockHTTPResponse(statusCode: 404, jsonText: "{}")
        }

        let service = LoginService(api: api, profile: profile)

        let noCred = await service.poll(edition: Edition.WWW, loginToken: "ltok_empty")
        XCTAssertEqual(noCred.state, .ERROR)
        XCTAssertNil(noCred.account)

        let preserved = await service.poll(edition: Edition.WWW, loginToken: "ltok_keep")
        XCTAssertEqual(preserved.state, .AUTHORIZED)
        XCTAssertEqual(preserved.account?.bearer, "fallback_keep_session_token")
    }

    func testStartHttp404ReturnsErrorNotExpired() async throws {
        let profile = try TestFixtures.loadProtocolProfile()
        let routerId = UUID().uuidString
        defer { MockTransportBox.shared.unregister(id: routerId) }

        let api = TestFixtures.makeMockApi(profile: profile, routerId: routerId) { _ in
            MockHTTPResponse(statusCode: 404, jsonText: #"{"code":404,"msg":"not found"}"#)
        }
        let service = LoginService(api: api, profile: profile)
        let started = await service.start(edition: Edition.WWW)
        XCTAssertEqual(started.state, .ERROR)
    }
}
