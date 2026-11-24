import Foundation
import XCTest
@testable import RainCheck

final class PhoneLoginClientTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeClient(
        profile: ProtocolProfile,
        handler: @escaping @Sendable (URLRequest) throws -> MockHTTPResponse
    ) -> PhoneLoginClient {
        let session = MockNetworkSupport.makeSession(handler: handler)
        return PhoneLoginClient(session: session, profile: profile)
    }

    private static func rawPathPreservingTrailingSlash(of request: URLRequest) -> String {
        guard let url = request.url else { return "" }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.path ?? url.path
    }

    // MARK: - Mainland Phone Validation & Captcha Policy

    func testMainlandPhoneValidation() throws {
        let validNumbers = [
            "13800138000",
            "14512345678",
            "15912345678",
            "16612345678",
            "17712345678",
            "18812345678",
            "19912345678",
            " 138-0013-8000 ",
            "138 0013 8000"
        ]
        for phone in validNumbers {
            XCTAssertTrue(
                PhoneLoginClient.isValidMainlandPhone(phone),
                "合法大陆手机号应校验通过: \(phone)"
            )
        }

        let invalidNumbers = [
            "",
            "   ",
            "10800138000",
            "11800138000",
            "12800138000",
            "23800138000",
            "1380013800",
            "138001380001",
            "1380013800a",
            "1380013800\u{FF10}",
            "+8613800138000",
            "abcdefg1234"
        ]
        for phone in invalidNumbers {
            XCTAssertFalse(
                PhoneLoginClient.isValidMainlandPhone(phone),
                "非法手机号格式必须拒绝: \(phone)"
            )
        }

        XCTAssertEqual(PhoneLoginClient.tencentCaptchaAppId, "2091064951")
        XCTAssertEqual(PhoneLoginClient.hcaptchaSiteKey, "50f6f060-c606-4e3b-b6e8-ca3b706b61e1")

        let profile = try TestBundleResources.loadProtocolProfile()
        for editionId in ["www", "pro", "changjiang", "huanghe"] {
            let edition = try XCTUnwrap(profile.edition(editionId))
            XCTAssertTrue(PhoneLoginClient.requiresWebCaptcha(for: edition))
        }
        let mockEdition = try XCTUnwrap(profile.edition("mock"))
        XCTAssertFalse(PhoneLoginClient.requiresWebCaptcha(for: mockEdition))
        XCTAssertFalse(
            PhoneLoginClient.requiresWebCaptcha(
                for: Edition(id: "local", label: "Local", host: "localhost:8787", scheme: "https")
            )
        )
    }

    // MARK: - Send SMS Verification Code

    func testSendSmsCodeRequestShapeAndSuccess() async throws {
        let profile = try TestBundleResources.loadProtocolProfile()
        let edition = try XCTUnwrap(profile.edition("www"))

        let methodSeen = LockedBox<String?>(nil)
        let urlSeen = LockedBox<String?>(nil)
        let pathSeen = LockedBox<String?>(nil)
        let originSeen = LockedBox<String?>(nil)
        let refererSeen = LockedBox<String?>(nil)
        let contentTypeSeen = LockedBox<String?>(nil)
        let acceptSeen = LockedBox<String?>(nil)
        let userAgentSeen = LockedBox<String?>(nil)
        let timeoutSeen = LockedBox<TimeInterval?>(nil)
        let bodySeen = LockedBox<[String: TemplateValue]?>(nil)

        let client = makeClient(profile: profile) { request in
            methodSeen.set(request.httpMethod)
            urlSeen.set(request.url?.absoluteString)
            pathSeen.set(Self.rawPathPreservingTrailingSlash(of: request))
            originSeen.set(MockNetworkSupport.headerValue("Origin", in: request))
            refererSeen.set(MockNetworkSupport.headerValue("Referer", in: request))
            contentTypeSeen.set(MockNetworkSupport.headerValue("Content-Type", in: request))
            acceptSeen.set(MockNetworkSupport.headerValue("Accept", in: request))
            userAgentSeen.set(MockNetworkSupport.headerValue("User-Agent", in: request))
            timeoutSeen.set(request.timeoutInterval)
            bodySeen.set(MockNetworkSupport.requestBodyJSON(from: request))
            return .json(200, #"{"success":true,"msg":""}"#)
        }

        let captcha = CaptchaToken(
            ticket: "t03-ticket-value",
            randstr: "@rand123",
            hcaptchaToken: ""
        )
        try await client.sendSmsCode(edition: edition, phone: "138-0013-8000", captcha: captcha)

        XCTAssertEqual(methodSeen.get(), "POST")
        XCTAssertEqual(
            urlSeen.get(),
            "https://www.yuketang.cn/pc/login/send_sms_login_code/",
            "必须严格保留 /pc/login/send_sms_login_code/ 末尾斜杠"
        )
        XCTAssertEqual(pathSeen.get(), "/pc/login/send_sms_login_code/")
        XCTAssertEqual(originSeen.get(), "https://www.yuketang.cn")
        XCTAssertNotEqual(originSeen.get(), "file://")
        XCTAssertEqual(refererSeen.get(), "https://www.yuketang.cn/web")
        XCTAssertEqual(contentTypeSeen.get(), "application/json")
        XCTAssertEqual(acceptSeen.get(), "application/json, text/plain, */*")
        XCTAssertEqual(userAgentSeen.get(), profile.userAgent)
        XCTAssertEqual(timeoutSeen.get(), RainCheckClient.defaultTimeoutInterval)

        let body = try XCTUnwrap(bodySeen.get())
        XCTAssertEqual(
            Set(body.keys),
            Set(["mobile", "login", "ticket", "randstr", "hcaptcha_token"])
        )
        XCTAssertEqual(body["mobile"], .string("13800138000"))
        XCTAssertEqual(body["login"], .bool(true))
        XCTAssertEqual(body["ticket"], .string("t03-ticket-value"))
        XCTAssertEqual(body["randstr"], .string("@rand123"))
        XCTAssertEqual(body["hcaptcha_token"], .string(""))

        // CFBoolean 防护：若服务端返回数值 1 而非布尔 true，绝不可误判为成功
        let nonBoolClient = makeClient(profile: profile) { _ in
            .json(200, #"{"success":1,"status_code":300408,"msg":"invalid bool"}"#)
        }
        do {
            try await nonBoolClient.sendSmsCode(edition: edition, phone: "13800138000", captcha: captcha)
            XCTFail("非 CFBoolean 的 success: 1 不应被误判为成功")
        } catch let error as PhoneLoginError {
            guard case .captchaRequired = error else {
                XCTFail("预期 300408 触发 .captchaRequired，实际为 \(error)")
                return
            }
        }
    }

    func testSendSmsCodeErrorStatusMapping() async throws {
        let profile = try TestBundleResources.loadProtocolProfile()
        let edition = try XCTUnwrap(profile.edition("www"))
        let captcha = CaptchaToken(ticket: "t1", randstr: "@r1")

        // 1) 300408: 发送短信验证码失败（防水墙未通过）-> .captchaRequired
        let client300408 = makeClient(profile: profile) { _ in
            .json(200, #"{"success":false,"status_code":300408,"msg":"发送短信验证码失败","data":{}}"#)
        }
        do {
            try await client300408.sendSmsCode(edition: edition, phone: "13800138000", captcha: captcha)
            XCTFail("300408 应抛出错误")
        } catch let error as PhoneLoginError {
            guard case .captchaRequired(let msg) = error else {
                XCTFail("300408 应映射为 .captchaRequired，实际为 \(error)")
                return
            }
            XCTAssertFalse(msg.isEmpty)
        }

        // 2) 300415: 频控 -> .serverError(code: 300415, ...)
        let client300415 = makeClient(profile: profile) { _ in
            .json(200, #"{"success":false,"status_code":300415,"msg":"too frequent","data":{}}"#)
        }
        do {
            try await client300415.sendSmsCode(edition: edition, phone: "13800138000", captcha: captcha)
            XCTFail("300415 应抛出错误")
        } catch let error as PhoneLoginError {
            guard case .serverError(let code, let msg) = error else {
                XCTFail("300415 应映射为 .serverError，实际为 \(error)")
                return
            }
            XCTAssertEqual(code, 300415)
            XCTAssertTrue(msg.contains("稍后再试"))
        }

        // 3) 300416: 腾讯防水墙校验失败 -> .captchaRequired
        let client300416 = makeClient(profile: profile) { _ in
            .json(200, #"{"success":false,"status_code":300416,"msg":"腾讯防水墙校验失败","data":{}}"#)
        }
        do {
            try await client300416.sendSmsCode(edition: edition, phone: "13800138000", captcha: captcha)
            XCTFail("300416 应抛出错误")
        } catch let error as PhoneLoginError {
            guard case .captchaRequired(let msg) = error else {
                XCTFail("300416 应映射为 .captchaRequired，实际为 \(error)")
                return
            }
            XCTAssertTrue(msg.contains("防水墙"))
        }

        // 4) 300402: 无效手机号格式 -> .serverError(code: 300402, ...)
        let client300402 = makeClient(profile: profile) { _ in
            .json(200, #"{"success":false,"status_code":300402,"msg":"invalid mobile","data":{}}"#)
        }
        do {
            try await client300402.sendSmsCode(edition: edition, phone: "13800138000", captcha: captcha)
            XCTFail("300402 应抛出错误")
        } catch let error as PhoneLoginError {
            guard case .serverError(let code, let msg) = error else {
                XCTFail("300402 应映射为 .serverError，实际为 \(error)")
                return
            }
            XCTAssertEqual(code, 300402)
            XCTAssertTrue(msg.contains("手机号"))
        }

        // 5) www.xuetangx.com 站点拒绝（本地拦截，零网络请求）
        let xuetangx = try XCTUnwrap(profile.edition("xuetangx"))
        let networkCalls = LockedBox(0)
        let xuetangxClient = makeClient(profile: profile) { _ in
            networkCalls.withLock { $0 += 1 }
            return .json(200, #"{"success":true}"#)
        }
        do {
            try await xuetangxClient.sendSmsCode(edition: xuetangx, phone: "13800138000", captcha: captcha)
            XCTFail("学堂在线应被拦截为 .unsupportedEdition")
        } catch let error as PhoneLoginError {
            guard case .unsupportedEdition(let msg) = error else {
                XCTFail("www.xuetangx.com 应抛出 .unsupportedEdition，实际为 \(error)")
                return
            }
            XCTAssertTrue(msg.contains("学堂在线"))
        }
        XCTAssertEqual(networkCalls.get(), 0)

        // 6) 本地手机号格式不合法（零网络请求）
        do {
            try await xuetangxClient.sendSmsCode(edition: edition, phone: "12345", captcha: captcha)
            XCTFail("非法手机号应抛出 .invalidPhone")
        } catch let error as PhoneLoginError {
            XCTAssertEqual(error, .invalidPhone)
        }
        XCTAssertEqual(networkCalls.get(), 0)
    }

    // MARK: - Login with SMS Code

    func testLoginWithSmsCodeSuccessAndSessionExtraction() async throws {
        let profile = try TestBundleResources.loadProtocolProfile()
        let edition = try XCTUnwrap(profile.edition("www"))

        let verifyMethodSeen = LockedBox<String?>(nil)
        let verifyURLSeen = LockedBox<String?>(nil)
        let verifyPathSeen = LockedBox<String?>(nil)
        let verifyOriginSeen = LockedBox<String?>(nil)
        let verifyRefererSeen = LockedBox<String?>(nil)
        let verifyBodySeen = LockedBox<[String: TemplateValue]?>(nil)
        let basicInfoCookieSeen = LockedBox<String?>(nil)
        let basicInfoCsrfSeen = LockedBox<String?>(nil)

        let client = makeClient(profile: profile) { request in
            let path = Self.rawPathPreservingTrailingSlash(of: request)
            switch path {
            case "/pc/login/verify_pwd_login/":
                verifyMethodSeen.set(request.httpMethod)
                verifyURLSeen.set(request.url?.absoluteString)
                verifyPathSeen.set(path)
                verifyOriginSeen.set(MockNetworkSupport.headerValue("Origin", in: request))
                verifyRefererSeen.set(MockNetworkSupport.headerValue("Referer", in: request))
                verifyBodySeen.set(MockNetworkSupport.requestBodyJSON(from: request))
                return .json(
                    200,
                    #"{"success":true,"msg":"","data":{}}"#,
                    headers: [
                        "Set-Cookie": "sessionid=sms-sid-1001; Path=/; HttpOnly, csrftoken=sms-csrf-1001; Path=/"
                    ]
                )
            case "/api/v3/user/basic-info":
                basicInfoCookieSeen.set(MockNetworkSupport.headerValue("Cookie", in: request))
                basicInfoCsrfSeen.set(MockNetworkSupport.headerValue("X-CSRFToken", in: request))
                return .json(
                    200,
                    #"{"code":0,"msg":"","data":{"id":"u2026","name":"赵同学"}}"#,
                    headers: ["set-auth": "Bearer sms-refreshed-tok"]
                )
            default:
                return .json(404, #"{"code":40400}"#)
            }
        }

        let account = try await client.loginWithSmsCode(
            edition: edition,
            phone: "138-0013-8000",
            code: "654321"
        )

        XCTAssertEqual(verifyMethodSeen.get(), "POST")
        XCTAssertEqual(
            verifyURLSeen.get(),
            "https://www.yuketang.cn/pc/login/verify_pwd_login/",
            "必须严格保留 /pc/login/verify_pwd_login/ 末尾斜杠"
        )
        XCTAssertEqual(verifyPathSeen.get(), "/pc/login/verify_pwd_login/")
        XCTAssertEqual(verifyOriginSeen.get(), "https://www.yuketang.cn")
        XCTAssertNotEqual(verifyOriginSeen.get(), "file://")
        XCTAssertEqual(verifyRefererSeen.get(), "https://www.yuketang.cn/web")

        let verifyBody = try XCTUnwrap(verifyBodySeen.get())
        XCTAssertEqual(Set(verifyBody.keys), Set(["type", "name", "pwd"]))
        XCTAssertEqual(verifyBody["type"], .string("PC"))
        XCTAssertEqual(verifyBody["name"], .string("13800138000"))
        XCTAssertEqual(verifyBody["pwd"], .string("654321"))

        let meCookie = try XCTUnwrap(basicInfoCookieSeen.get())
        XCTAssertTrue(meCookie.contains("sessionid=sms-sid-1001"))
        XCTAssertTrue(meCookie.contains("csrftoken=sms-csrf-1001"))
        XCTAssertEqual(basicInfoCsrfSeen.get(), "sms-csrf-1001")

        XCTAssertEqual(account.sessionId, "sms-sid-1001")
        XCTAssertEqual(account.csrfToken, "sms-csrf-1001")
        XCTAssertEqual(account.bearer, "sms-refreshed-tok")
        XCTAssertEqual(account.userId, "u2026")
        XCTAssertEqual(account.label, "赵同学")
        XCTAssertEqual(account.host, "www.yuketang.cn")
        XCTAssertEqual(account.scheme, "https")
        XCTAssertTrue(account.hasCredential)
        XCTAssertGreaterThan(account.createdAt, 0)
        XCTAssertNotNil(account.lastOkAt)

        // 兼容分号拼接的 Set-Cookie: sessionid=...; csrftoken=...
        let semicolonClient = makeClient(profile: profile) { request in
            let path = Self.rawPathPreservingTrailingSlash(of: request)
            if path == "/pc/login/verify_pwd_login/" {
                return .json(
                    200,
                    #"{"success":true}"#,
                    headers: ["Set-Cookie": "sessionid=sms-sid-semi; csrftoken=sms-csrf-semi"]
                )
            }
            if path == "/api/v3/user/basic-info" {
                return .json(200, #"{"code":0,"data":{"id":"u2027","name":"钱同学"}}"#)
            }
            return .json(404, #"{"code":40400}"#)
        }
        let semiAccount = try await semicolonClient.loginWithSmsCode(
            edition: edition,
            phone: "13900139000",
            code: "123456"
        )
        XCTAssertEqual(semiAccount.sessionId, "sms-sid-semi")
        XCTAssertEqual(semiAccount.csrfToken, "sms-csrf-semi")
        XCTAssertEqual(semiAccount.userId, "u2027")
        XCTAssertEqual(semiAccount.label, "钱同学")
    }

    func testLoginWithSmsCodeDegradedBasicInfoPreservesCookies() async throws {
        let profile = try TestBundleResources.loadProtocolProfile()
        let edition = try XCTUnwrap(profile.edition("www"))

        let client = makeClient(profile: profile) { request in
            let path = Self.rawPathPreservingTrailingSlash(of: request)
            switch path {
            case "/pc/login/verify_pwd_login/":
                return .json(
                    200,
                    #"{"success":true,"msg":""}"#,
                    headers: [
                        "Set-Cookie": "sessionid=sms-sid-deg; Path=/; HttpOnly, csrftoken=sms-csrf-deg; Path=/"
                    ]
                )
            case "/api/v3/user/basic-info":
                return .json(500, #"{"code":50000,"msg":"用户信息接口暂时不可用"}"#)
            default:
                return .json(404, #"{"code":40400}"#)
            }
        }

        let account = try await client.loginWithSmsCode(
            edition: edition,
            phone: "13800138000",
            code: "123456"
        )

        XCTAssertEqual(account.sessionId, "sms-sid-deg")
        XCTAssertEqual(account.csrfToken, "sms-csrf-deg")
        XCTAssertNil(account.bearer)
        XCTAssertTrue(account.hasCredential)
        XCTAssertEqual(account.host, "www.yuketang.cn")
        XCTAssertEqual(account.scheme, "https")
        XCTAssertEqual(account.label, "雨课堂用户(8000)")
        XCTAssertFalse(account.label.contains("13800138000"), "降级兜底标签应脱敏，不得直接暴露完整手机号")
        XCTAssertNil(account.userId)
        XCTAssertGreaterThan(account.createdAt, 0)
        XCTAssertNil(account.lastOkAt, "basic-info 返回 HTTP 500 降级时不应强行写入 lastOkAt")
    }

    func testLoginWithSmsCodeRejectsEmptyCredentialsAndMapsCodeErrors() async throws {
        let profile = try TestBundleResources.loadProtocolProfile()
        let edition = try XCTUnwrap(profile.edition("www"))

        // 1) 300404 / 300405 / 300417 业务错误码映射
        let expectedCodeErrors: [(code: Int, expectedKeyword: String)] = [
            (300404, "过期"),
            (300405, "错误"),
            (300417, "绑定")
        ]
        for item in expectedCodeErrors {
            let expectedCode = item.code
            let client = makeClient(profile: profile) { _ in
                .json(200, #"{"success":false,"status_code":\#(expectedCode),"msg":"server error","data":{}}"#)
            }
            do {
                _ = try await client.loginWithSmsCode(edition: edition, phone: "13800138000", code: "123456")
                XCTFail("status_code \(item.code) 应抛出 PhoneLoginError.serverError")
            } catch let error as PhoneLoginError {
                guard case .serverError(let code, let msg) = error else {
                    XCTFail("status_code \(item.code) 预期映射为 .serverError，实际为 \(error)")
                    return
                }
                XCTAssertEqual(code, item.code)
                XCTAssertTrue(msg.contains(item.expectedKeyword), "错误文案应包含 '\(item.expectedKeyword)'，实际为 \(msg)")
            }
        }

        // 2) success: true 但没有任何 Cookie 或 Bearer -> .missingCredentials（不调用 basic-info）
        let basicInfoCalls = LockedBox(0)
        let emptyCredClient = makeClient(profile: profile) { request in
            if request.url?.path == "/api/v3/user/basic-info" {
                basicInfoCalls.withLock { $0 += 1 }
            }
            return .json(200, #"{"success":true,"msg":"ok","data":{}}"#)
        }
        do {
            _ = try await emptyCredClient.loginWithSmsCode(edition: edition, phone: "13800138000", code: "123456")
            XCTFail("缺少 sessionid 与 bearer 时必须抛出 .missingCredentials")
        } catch let error as PhoneLoginError {
            XCTAssertEqual(error, .missingCredentials)
        }
        XCTAssertEqual(basicInfoCalls.get(), 0)

        // 3) 仅有 csrftoken 或过期 sessionid -> 仍拒绝并抛出 .missingCredentials
        let csrfOnlyClient = makeClient(profile: profile) { request in
            if request.url?.path == "/api/v3/user/basic-info" {
                basicInfoCalls.withLock { $0 += 1 }
            }
            return .json(
                200,
                #"{"success":true}"#,
                headers: ["Set-Cookie": "csrftoken=only-csrf; Path=/, sessionid=; Max-Age=0; Path=/"]
            )
        }
        do {
            _ = try await csrfOnlyClient.loginWithSmsCode(edition: edition, phone: "13800138000", code: "123456")
            XCTFail("仅含 csrftoken 或 Max-Age=0 空 sessionid 时必须抛出 .missingCredentials")
        } catch let error as PhoneLoginError {
            XCTAssertEqual(error, .missingCredentials)
        }
        XCTAssertEqual(basicInfoCalls.get(), 0)

        // 4) 本地非法验证码拦截（零网络请求）
        let codeValidationCalls = LockedBox(0)
        let validationClient = makeClient(profile: profile) { _ in
            codeValidationCalls.withLock { $0 += 1 }
            return .json(200, #"{"success":true}"#)
        }
        for badCode in ["", "123", "123456789", "12ab56"] {
            do {
                _ = try await validationClient.loginWithSmsCode(edition: edition, phone: "13800138000", code: badCode)
                XCTFail("非法验证码 \(badCode) 应抛出 .invalidCode")
            } catch let error as PhoneLoginError {
                XCTAssertEqual(error, .invalidCode)
            }
        }
        XCTAssertEqual(codeValidationCalls.get(), 0)
    }

    // MARK: - Web Headers Across Editions, Django Multi-Cookie & Stale Bearer Fallback

    func testLoginWithSmsCodeFetchMeSendsCleanWebHeadersAcrossEditions() async throws {
        struct CapturedMeHeaders: Sendable {
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
        let editionIds = ["www", "pro", "changjiang", "huanghe", "mock"]

        for editionId in editionIds {
            let edition = try XCTUnwrap(profile.edition(editionId), "profile 应包含站点 \(editionId)")
            let expectedOrigin = "\(edition.scheme)://\(edition.host)"
            let expectedReferer = "\(expectedOrigin)/v2/web/index"

            let loginDesktopVSeen = LockedBox<String?>(nil)
            let meHeadersSeen = LockedBox<CapturedMeHeaders?>(nil)

            let client = makeClient(profile: profile) { request in
                let path = Self.rawPathPreservingTrailingSlash(of: request)
                switch path {
                case "/pc/login/verify_pwd_login/":
                    loginDesktopVSeen.set(MockNetworkSupport.headerValue("desktop-v", in: request))
                    return .json(
                        200,
                        #"{"success":true,"msg":"","data":{}}"#,
                        headers: [
                            "Set-Cookie": "sessionid=web-sid-\(editionId); HttpOnly; Path=/, csrftoken=web-csrf-\(editionId); Path=/"
                        ]
                    )
                case "/api/v3/user/basic-info":
                    let captured = CapturedMeHeaders(
                        xClient: MockNetworkSupport.headerValue("X-Client", in: request),
                        xtbz: MockNetworkSupport.headerValue("xtbz", in: request),
                        origin: MockNetworkSupport.headerValue("Origin", in: request),
                        referer: MockNetworkSupport.headerValue("Referer", in: request),
                        desktopV: MockNetworkSupport.headerValue("desktop-v", in: request),
                        authorization: MockNetworkSupport.headerValue("Authorization", in: request),
                        cookie: MockNetworkSupport.headerValue("Cookie", in: request),
                        csrfHeader: MockNetworkSupport.headerValue("X-CSRFToken", in: request)
                    )
                    meHeadersSeen.set(captured)
                    // 模拟真实雨课堂网关：携带 desktop-v / X-Client: desktop / Origin: file:// 时拒签 Web Cookie
                    if captured.desktopV != nil || captured.xClient != "web" || captured.origin == "file://" {
                        return .json(401, #"{"code":401,"msg":"登录失效，请重新登录"}"#)
                    }
                    return .json(
                        200,
                        #"{"code":0,"msg":"","data":{"id":"uid-\#(editionId)","name":"用户-\#(editionId)"}}"#
                    )
                default:
                    return .json(404, #"{"code":40400}"#)
                }
            }

            let account = try await client.loginWithSmsCode(
                edition: edition,
                phone: "13800138000",
                code: "654321"
            )

            XCTAssertNil(loginDesktopVSeen.get(), "\(editionId) 登录请求不应发送 desktop-v")
            let meHeaders = try XCTUnwrap(meHeadersSeen.get(), "\(editionId) 必须调用 basic-info")
            XCTAssertEqual(meHeaders.xClient, "web", "\(editionId) fetchMe 必须发送 X-Client: web")
            XCTAssertEqual(meHeaders.xtbz, "ykt", "\(editionId) fetchMe 必须发送 xtbz: ykt")
            XCTAssertEqual(meHeaders.origin, expectedOrigin, "\(editionId) fetchMe Origin 必须同源")
            XCTAssertNotEqual(meHeaders.origin, "file://", "\(editionId) fetchMe 绝不能发送 Origin: file://")
            XCTAssertEqual(meHeaders.referer, expectedReferer, "\(editionId) fetchMe Referer 必须指向 /v2/web/index")
            XCTAssertNil(meHeaders.desktopV, "\(editionId) fetchMe 绝不能发送 desktop-v")
            XCTAssertNil(meHeaders.authorization, "\(editionId) 纯 Cookie 登录不应发送 Authorization")
            XCTAssertTrue(meHeaders.cookie?.contains("sessionid=web-sid-\(editionId)") == true)
            XCTAssertTrue(meHeaders.cookie?.contains("csrftoken=web-csrf-\(editionId)") == true)
            XCTAssertEqual(meHeaders.csrfHeader, "web-csrf-\(editionId)")

            XCTAssertEqual(account.sessionId, "web-sid-\(editionId)")
            XCTAssertEqual(account.csrfToken, "web-csrf-\(editionId)")
            XCTAssertEqual(account.userId, "uid-\(editionId)")
            XCTAssertEqual(account.label, "用户-\(editionId)")
            XCTAssertNotNil(account.lastOkAt)
        }

        // 防御性清洗校验：即使传入历史桌面端 headers 配置，fetchMe 也必须强制清理为同源 Web 请求头
        let legacyProfile = ProtocolProfile(
            version: profile.version,
            name: profile.name,
            updatedAt: profile.updatedAt,
            defaultEdition: profile.defaultEdition,
            editions: profile.editions,
            headers: [
                "xtbz": "ykt",
                "desktop-v": "v2",
                "X-Client": "desktop",
                "Origin": "file://",
                "Accept": "application/json, text/plain, */*"
            ],
            userAgent: profile.userAgent,
            auth: profile.auth,
            endpoints: profile.endpoints,
            strategies: profile.strategies,
            qr: profile.qr,
            result: profile.result
        )
        let wwwEdition = try XCTUnwrap(legacyProfile.edition("www"))
        let sanitizedHeaders = LockedBox<CapturedMeHeaders?>(nil)
        let legacyClient = makeClient(profile: legacyProfile) { request in
            let path = Self.rawPathPreservingTrailingSlash(of: request)
            if path == "/pc/login/verify_pwd_login/" {
                return .json(
                    200,
                    #"{"success":true,"msg":""}"#,
                    headers: ["Set-Cookie": "sessionid=legacy-sid; HttpOnly; Path=/"]
                )
            }
            if path == "/api/v3/user/basic-info" {
                sanitizedHeaders.set(
                    CapturedMeHeaders(
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
                return .json(200, #"{"code":0,"data":{"id":"u-legacy","name":"老配置用户"}}"#)
            }
            return .json(404, #"{"code":40400}"#)
        }
        let legacyAccount = try await legacyClient.loginWithSmsCode(
            edition: wwwEdition,
            phone: "13800138000",
            code: "123456"
        )
        let cleaned = try XCTUnwrap(sanitizedHeaders.get())
        XCTAssertEqual(cleaned.xClient, "web")
        XCTAssertEqual(cleaned.xtbz, "ykt")
        XCTAssertEqual(cleaned.origin, "https://www.yuketang.cn")
        XCTAssertNotEqual(cleaned.origin, "file://")
        XCTAssertEqual(cleaned.referer, "https://www.yuketang.cn/v2/web/index")
        XCTAssertNil(cleaned.desktopV)
        XCTAssertEqual(legacyAccount.label, "老配置用户")
    }

    func testDjangoMultiCookieSetCookieWithExpiresCommaParsesBothSessionAndCsrf() async throws {
        let djangoSetCookie =
            "csrftoken=csrf_django_2027_val; expires=Tue, 23-Nov-2027 11:52:14 GMT; Max-Age=31449600; Path=/, sessionid=real_sid_value; HttpOnly; Path=/"

        // 1) 直接测试 CredentialSanitizer 拆分与提取：绝不被 expires 日期逗号截断，绝不泄漏 Cookie 属性
        let entries = CredentialSanitizer.splitSetCookieHeader(djangoSetCookie)
        XCTAssertEqual(entries.count, 2, "expires 日期中的逗号不可拆段，应精确拆分为 2 条 Cookie")
        XCTAssertTrue(entries[0].hasPrefix("csrftoken=csrf_django_2027_val"))
        XCTAssertTrue(entries[1].hasPrefix("sessionid=real_sid_value"))

        let parsedSession = CredentialSanitizer.cleanCookieValue(djangoSetCookie, key: "sessionid")
        let parsedCsrf = CredentialSanitizer.cleanCookieValue(djangoSetCookie, key: "csrftoken")
        XCTAssertEqual(parsedSession, "real_sid_value")
        XCTAssertEqual(parsedCsrf, "csrf_django_2027_val")

        let prefixedReversed =
            "Set-Cookie: sessionid=real_sid_value; expires=Tue, 23-Nov-2027 11:52:14 GMT; HttpOnly; Path=/, csrftoken=csrf_django_2027_val; Max-Age=31449600; Path=/"
        XCTAssertEqual(CredentialSanitizer.cleanCookieValue(prefixedReversed, key: "sessionid"), "real_sid_value")
        XCTAssertEqual(CredentialSanitizer.cleanCookieValue(prefixedReversed, key: "csrftoken"), "csrf_django_2027_val")

        // 2) 端到端测试 PhoneLoginClient.loginWithSmsCode 提取与透传至 basic-info
        let profile = try TestBundleResources.loadProtocolProfile()
        let edition = try XCTUnwrap(profile.edition("www"))
        let meCookieSeen = LockedBox<String?>(nil)
        let meCsrfSeen = LockedBox<String?>(nil)

        let client = makeClient(profile: profile) { request in
            let path = Self.rawPathPreservingTrailingSlash(of: request)
            switch path {
            case "/pc/login/verify_pwd_login/":
                return .json(
                    200,
                    #"{"success":true,"msg":"","data":{}}"#,
                    headers: ["Set-Cookie": djangoSetCookie]
                )
            case "/api/v3/user/basic-info":
                meCookieSeen.set(MockNetworkSupport.headerValue("Cookie", in: request))
                meCsrfSeen.set(MockNetworkSupport.headerValue("X-CSRFToken", in: request))
                return .json(200, #"{"code":0,"msg":"","data":{"id":"u-django","name":"孙同学"}}"#)
            default:
                return .json(404, #"{"code":40400}"#)
            }
        }

        let account = try await client.loginWithSmsCode(
            edition: edition,
            phone: "13800138000",
            code: "654321"
        )

        XCTAssertEqual(account.sessionId, "real_sid_value")
        XCTAssertEqual(account.csrfToken, "csrf_django_2027_val")
        XCTAssertEqual(account.userId, "u-django")
        XCTAssertEqual(account.label, "孙同学")
        XCTAssertNotNil(account.lastOkAt)

        let sentCookie = try XCTUnwrap(meCookieSeen.get())
        XCTAssertTrue(sentCookie.contains("sessionid=real_sid_value"))
        XCTAssertTrue(sentCookie.contains("csrftoken=csrf_django_2027_val"))
        for leakedAttr in ["expires", "Max-Age", "Path=", "HttpOnly", ","] {
            XCTAssertFalse(sentCookie.contains(leakedAttr), "Cookie 请求头不得泄漏属性片段: \(leakedAttr)")
        }
        XCTAssertEqual(meCsrfSeen.get(), "csrf_django_2027_val")
    }

    func testFetchMeRetriesCookieOnlyWhenStaleBearerFailsWith401() async throws {
        struct MeAttempt: Sendable {
            let authorization: String?
            let cookie: String?
            let csrfHeader: String?
            let xClient: String?
            let xtbz: String?
            let origin: String?
            let referer: String?
            let desktopV: String?
        }

        let profile = try TestBundleResources.loadProtocolProfile()
        let attempts = LockedBox<[MeAttempt]>([])

        let session = MockNetworkSupport.makeSession { request in
            let auth = MockNetworkSupport.headerValue("Authorization", in: request)
            let cookie = MockNetworkSupport.headerValue("Cookie", in: request)
            attempts.withLock {
                $0.append(
                    MeAttempt(
                        authorization: auth,
                        cookie: cookie,
                        csrfHeader: MockNetworkSupport.headerValue("X-CSRFToken", in: request),
                        xClient: MockNetworkSupport.headerValue("X-Client", in: request),
                        xtbz: MockNetworkSupport.headerValue("xtbz", in: request),
                        origin: MockNetworkSupport.headerValue("Origin", in: request),
                        referer: MockNetworkSupport.headerValue("Referer", in: request),
                        desktopV: MockNetworkSupport.headerValue("desktop-v", in: request)
                    )
                )
            }

            if auth != nil {
                return .json(401, #"{"code":401,"msg":"登录失效，请重新登录"}"#)
            }
            if cookie?.contains("sessionid=valid-web-sid-888") == true {
                return .json(200, #"{"code":0,"msg":"","data":{"id":"u-5566","name":"陈同学"}}"#)
            }
            return .json(401, #"{"code":401,"msg":"缺少有效会话"}"#)
        }

        let rainClient = RainCheckClient(session: session, profile: profile)
        let staleAccount = Account(
            id: "acc-stale-bearer",
            label: "雨课堂用户(8000)",
            host: "changjiang.yuketang.cn",
            scheme: "https",
            bearer: "stale-lesson-bearer-999",
            sessionId: "valid-web-sid-888",
            csrfToken: "valid-web-csrf-777"
        )

        let verified = try await rainClient.fetchMe(account: staleAccount)

        let recorded = attempts.get()
        XCTAssertEqual(recorded.count, 2, "首次携带过期 Bearer 401 后应自动回退纯 Cookie 重试一次")
        XCTAssertEqual(recorded[0].authorization, "Bearer stale-lesson-bearer-999")
        XCTAssertNil(recorded[1].authorization, "第二次纯 Cookie 重试绝不能携带 Authorization 头")
        XCTAssertTrue(recorded[1].cookie?.contains("sessionid=valid-web-sid-888") == true)
        XCTAssertTrue(recorded[1].cookie?.contains("csrftoken=valid-web-csrf-777") == true)
        XCTAssertEqual(recorded[1].csrfHeader, "valid-web-csrf-777")

        for attempt in recorded {
            XCTAssertEqual(attempt.xClient, "web")
            XCTAssertEqual(attempt.xtbz, "ykt")
            XCTAssertEqual(attempt.origin, "https://changjiang.yuketang.cn")
            XCTAssertNotEqual(attempt.origin, "file://")
            XCTAssertEqual(attempt.referer, "https://changjiang.yuketang.cn/v2/web/index")
            XCTAssertNil(attempt.desktopV)
        }

        XCTAssertEqual(verified.userId, "u-5566")
        XCTAssertEqual(verified.name, "陈同学")
        let refreshed = try XCTUnwrap(verified.refreshedAccount)
        XCTAssertNil(refreshed.bearer, "纯 Cookie 重试成功后必须清除已过期的旧 bearer")
        XCTAssertEqual(refreshed.sessionId, "valid-web-sid-888")
        XCTAssertEqual(refreshed.csrfToken, "valid-web-csrf-777")
        XCTAssertEqual(refreshed.userId, "u-5566")
        XCTAssertEqual(refreshed.label, "陈同学")
        XCTAssertNotNil(refreshed.lastOkAt)
    }

    @MainActor
    func testAppStoreVerifyAccountUpgradesPlaceholderLabelAndPreservesCustomLabel() async throws {
        XCTAssertTrue(Account.isPlaceholderLabel("雨课堂用户(8000)"))
        XCTAssertTrue(Account.isPlaceholderLabel("账号 1"))
        XCTAssertTrue(Account.isPlaceholderLabel("   "))
        XCTAssertFalse(Account.isPlaceholderLabel("周同学"))
        XCTAssertFalse(Account.isPlaceholderLabel("我的主号"))

        let profile = try TestBundleResources.loadProtocolProfile()
        let vault = InMemoryAccountVault()

        let session = MockNetworkSupport.makeSession { request in
            let auth = MockNetworkSupport.headerValue("Authorization", in: request)
            let cookie = MockNetworkSupport.headerValue("Cookie", in: request) ?? ""
            if auth != nil {
                return .json(401, #"{"code":401,"msg":"登录失效，请重新登录"}"#)
            }
            if cookie.contains("sessionid=sid-placeholder-8000") {
                return .json(200, #"{"code":0,"msg":"","data":{"id":"u-8000","name":"周同学"}}"#)
            }
            if cookie.contains("sessionid=sid-custom-9000") {
                return .json(200, #"{"code":0,"msg":"","data":{"id":"u-9000","name":"服务端真实姓名"}}"#)
            }
            return .json(401, #"{"code":401,"msg":"登录失效，请重新登录"}"#)
        }

        let store = AppStore(vault: vault, profile: profile, session: session)
        let placeholderAccount = Account(
            id: "acc-placeholder-8000",
            label: "雨课堂用户(8000)",
            host: "www.yuketang.cn",
            scheme: "https",
            bearer: "stale-jwt-8000",
            sessionId: "sid-placeholder-8000",
            csrfToken: "csrf-8000",
            lastOkAt: nil,
            userId: nil
        )
        let customAccount = Account(
            id: "acc-custom-9000",
            label: "我的主号",
            host: "pro.yuketang.cn",
            scheme: "https",
            bearer: nil,
            sessionId: "sid-custom-9000",
            csrfToken: "csrf-9000",
            lastOkAt: nil,
            userId: nil
        )
        try store.addOrUpdateAccount(placeholderAccount)
        try store.addOrUpdateAccount(customAccount)

        await store.verifyAccount(id: "acc-placeholder-8000")

        let upgraded = try XCTUnwrap(store.accounts.first(where: { $0.id == "acc-placeholder-8000" }))
        XCTAssertEqual(upgraded.label, "周同学", "占位标签 雨课堂用户(8000) 在 verifyAccount 通过后必须升级为真实用户名")
        XCTAssertEqual(upgraded.userId, "u-8000")
        XCTAssertNil(upgraded.bearer, "verifyAccount 经纯 Cookie 回退成功后应同步清理失效 bearer")
        XCTAssertEqual(upgraded.sessionId, "sid-placeholder-8000")
        XCTAssertNotNil(upgraded.lastOkAt)
        XCTAssertEqual(store.toastMessage, "验证通过：周同学")

        let persistedUpgraded = try XCTUnwrap(vault.load().first(where: { $0.id == "acc-placeholder-8000" }))
        XCTAssertEqual(persistedUpgraded.label, "周同学")
        XCTAssertNil(persistedUpgraded.bearer)
        XCTAssertEqual(persistedUpgraded.userId, "u-8000")

        // 用户自定义标签绝不被服务端用户名覆盖
        await store.verifyAccount(id: "acc-custom-9000")
        let preserved = try XCTUnwrap(store.accounts.first(where: { $0.id == "acc-custom-9000" }))
        XCTAssertEqual(preserved.label, "我的主号")
        XCTAssertEqual(preserved.userId, "u-9000")
        XCTAssertNotNil(preserved.lastOkAt)
    }
}
