import Foundation
import XCTest
@testable import RainCheck

final class QrCodeParserTests: XCTestCase {
    private func loadMasterProfile() throws -> ProtocolProfile {
        try TestBundleResources.loadProtocolProfile()
    }

    // MARK: - 20 Cross-Platform Protocol Vectors

    func testAllTwentyProtocolQrVectors() throws {
        let profile = try loadMasterProfile()
        let vectorFile = try TestBundleResources.loadQrVectorFile()

        XCTAssertEqual(vectorFile.version, 1)
        XCTAssertEqual(
            vectorFile.cases.count,
            20,
            "protocol/vectors/qr_cases.json 必须完整加载并校验全部 20 条测试向量"
        )

        for tc in vectorFile.cases {
            let ticket = QrCodeParser.parse(tc.raw, profile: profile)
            XCTAssertEqual(
                ticket.kind.rawValue,
                tc.expect.kind,
                "用例 [\(tc.name)] kind 不匹配，raw=\(tc.raw)"
            )

            if let expectedHost = tc.expect.host {
                XCTAssertEqual(ticket.host, expectedHost, "用例 [\(tc.name)] host 不匹配")
            }
            if let expectedLessonId = tc.expect.lessonId {
                XCTAssertEqual(ticket.lessonId, expectedLessonId, "用例 [\(tc.name)] lessonId 不匹配")
            }
            if let expectedClassroomId = tc.expect.classroomId {
                XCTAssertEqual(ticket.classroomId, expectedClassroomId, "用例 [\(tc.name)] classroomId 不匹配")
            }
            if let expectedCheckinId = tc.expect.checkinId {
                XCTAssertEqual(ticket.checkinId, expectedCheckinId, "用例 [\(tc.name)] checkinId 不匹配")
            }
            if let expectedParams = tc.expect.params {
                XCTAssertEqual(ticket.params, expectedParams, "用例 [\(tc.name)] params 不匹配")
                if let expectedC = expectedParams["c"] {
                    XCTAssertEqual(ticket.dynamicCode, expectedC, "用例 [\(tc.name)] dynamicCode(c) 不匹配")
                }
                if let expectedT = expectedParams["t"] {
                    XCTAssertEqual(ticket.timestamp, expectedT, "用例 [\(tc.name)] timestamp(t) 不匹配")
                }
                if let expectedS = expectedParams["s"] {
                    XCTAssertEqual(ticket.signature, expectedS, "用例 [\(tc.name)] signature(s) 不匹配")
                }
            }
        }
    }

    func testCheckinIdAliasesAndTimestampEpochExtraction() throws {
        let profile = try loadMasterProfile()

        let ticket1 = QrCodeParser.parse(
            "https://www.yuketang.cn/api/v3/lesson/checkin?c=tk01&t=1763900000&s=sig1&lessonId=101&classroomId=202&checkinId=303",
            profile: profile
        )
        XCTAssertEqual(ticket1.kind, .dynamicCheckin)
        XCTAssertEqual(ticket1.lessonId, "101")
        XCTAssertEqual(ticket1.classroomId, "202")
        XCTAssertEqual(ticket1.checkinId, "303")
        XCTAssertEqual(ticket1.dynamicCode, "tk01")
        XCTAssertEqual(ticket1.timestamp, "1763900000")
        XCTAssertEqual(ticket1.signature, "sig1")
        XCTAssertEqual(ticket1.issuedAtEpochSeconds, 1_763_900_000)

        let ticket2 = QrCodeParser.parse(
            "https://pro.yuketang.cn/api/v3/lesson/checkin?c=tk02&t=1763900000500&s=sig2&sign_id=404&lesson_id=505",
            profile: profile
        )
        XCTAssertEqual(ticket2.kind, .dynamicCheckin)
        XCTAssertEqual(ticket2.checkinId, "404")
        XCTAssertEqual(ticket2.lessonId, "505")
        XCTAssertEqual(ticket2.issuedAtEpochSeconds ?? 0, 1_763_900_000.5, accuracy: 0.001)
    }

    func testDynamicKeysAndLoginPathHintsRespectProfileConfig() throws {
        let profile = try loadMasterProfile()

        let customDynamicProfile = ProtocolProfile(
            version: profile.version,
            name: profile.name,
            updatedAt: profile.updatedAt,
            defaultEdition: profile.defaultEdition,
            editions: profile.editions,
            headers: profile.headers,
            userAgent: profile.userAgent,
            auth: profile.auth,
            endpoints: profile.endpoints,
            strategies: profile.strategies,
            qr: QrSpec(
                dynamicKeys: ["code", "ts"],
                lessonKeys: profile.qr.lessonKeys,
                classroomKeys: profile.qr.classroomKeys,
                checkinKeys: profile.qr.checkinKeys,
                loginPathHints: profile.qr.loginPathHints,
                schemes: profile.qr.schemes,
                allowedUrlHosts: profile.qr.allowedUrlHosts
            ),
            result: profile.result
        )
        let matched = QrCodeParser.parse(
            "https://www.yuketang.cn/x?code=abc&ts=1763900000",
            profile: customDynamicProfile
        )
        XCTAssertEqual(matched.kind, .dynamicCheckin)

        let unmatched = QrCodeParser.parse("c=abc&t=1763900000&s=sig", profile: customDynamicProfile)
        XCTAssertEqual(unmatched.kind, .unknown)

        // loginPathHints 仅匹配 path，绝不误匹配 host
        let hostOnlyLogin = QrCodeParser.parse("https://login.evil.example/v2/web/index", profile: profile)
        XCTAssertEqual(hostOnlyLogin.kind, .unknown)

        let customLoginProfile = ProtocolProfile(
            version: profile.version,
            name: profile.name,
            updatedAt: profile.updatedAt,
            defaultEdition: profile.defaultEdition,
            editions: profile.editions,
            headers: profile.headers,
            userAgent: profile.userAgent,
            auth: profile.auth,
            endpoints: profile.endpoints,
            strategies: profile.strategies,
            qr: QrSpec(
                dynamicKeys: profile.qr.dynamicKeys,
                lessonKeys: profile.qr.lessonKeys,
                classroomKeys: profile.qr.classroomKeys,
                checkinKeys: profile.qr.checkinKeys,
                loginPathHints: ["custom-auth"],
                schemes: profile.qr.schemes,
                allowedUrlHosts: profile.qr.allowedUrlHosts
            ),
            result: profile.result
        )
        let pathMatched = QrCodeParser.parse(
            "https://www.yuketang.cn/custom-auth/step1",
            profile: customLoginProfile
        )
        XCTAssertEqual(pathMatched.kind, .login)
    }

    func testMasterProtocolProfileIntegrityAndFallbackParity() throws {
        let profile = try loadMasterProfile()

        XCTAssertEqual(profile.updatedAt, "2026-11-24")
        XCTAssertEqual(profile.editions.count, 7)
        XCTAssertEqual(profile.edition("tsinghua")?.host, "pro.yuketang.cn")
        XCTAssertEqual(profile.edition("pro")?.host, "pro.yuketang.cn")
        XCTAssertEqual(profile.edition("xuetangx")?.host, "www.xuetangx.com")
        XCTAssertEqual(profile.endpoint("locationEligibility")?.auth, true)
        XCTAssertEqual(profile.endpoint("checkinList")?.method, "POST")
        XCTAssertEqual(profile.endpoint("checkinDetail")?.method, "POST")
        XCTAssertEqual(profile.endpoint("locationUpdateSession")?.path, "/api/v3/location-checkin/update-session")
        XCTAssertTrue(profile.qr.schemes.contains("app"))
        XCTAssertTrue(profile.result.altCodeKeys.contains("errcode"))
        XCTAssertTrue(profile.result.altMessageKeys.contains("errmsg"))
        XCTAssertFalse(profile.result.alreadyKeywords.contains("签到成功"))

        // 验证内置 fallback 与主 profile 策略链及站点一致
        let fallback = ProtocolCatalog.fallback
        XCTAssertEqual(fallback.editions.map(\.id), profile.editions.map(\.id))
        XCTAssertEqual(fallback.strategies.map(\.id), profile.strategies.map(\.id))
        XCTAssertEqual(fallback.qr.allowedUrlHosts, profile.qr.allowedUrlHosts)
    }

    // MARK: - validateQrUrl Security Guard

    func testValidateQrUrlSameOriginAllowlistMaliciousAndDisallowedSchemes() throws {
        let profile = try loadMasterProfile()
        let prodAccount = Account(id: "a1", label: "学生", host: "www.yuketang.cn", scheme: "https", bearer: "tok")
        let mockAccount = Account(id: "a2", label: "演练", host: "127.0.0.1:18787", scheme: "http", bearer: "tok")
        let customCampus = Account(id: "a3", label: "私有校", host: "campus.example.edu.cn", scheme: "https", bearer: "tok")

        // 放行：同源、白名单、默认端口归一化、大小写不敏感、演练本地 HTTP
        XCTAssertTrue(QrCodeParser.validateQrUrl("https://www.yuketang.cn/api/v3/lesson/checkin?c=1", account: prodAccount, profile: profile))
        XCTAssertTrue(QrCodeParser.validateQrUrl("https://PRO.YUKETANG.CN:443/api/v3/lesson/checkin?c=1", account: prodAccount, profile: profile))
        XCTAssertTrue(QrCodeParser.validateQrUrl("http://127.0.0.1:8787/api/v3/lesson/checkin?c=1", account: prodAccount, profile: profile))
        XCTAssertTrue(QrCodeParser.validateQrUrl("http://127.0.0.1:18787/api/v3/lesson/checkin?c=1", account: mockAccount, profile: profile))
        XCTAssertTrue(QrCodeParser.validateQrUrl("https://campus.example.edu.cn/api/v3/lesson/checkin?c=1", account: customCampus, profile: profile))
        XCTAssertTrue(QrCodeParser.validateQrUrl("https://campus.example.edu.cn/x?c=1", accountHost: "https://campus.example.edu.cn", profile: profile))

        // 阻断：恶意第三方域名、前缀/后缀伪造、userinfo @ 欺骗、反斜杠欺骗
        XCTAssertFalse(QrCodeParser.validateQrUrl("https://evil.example/x?c=1", account: prodAccount, profile: profile))
        XCTAssertFalse(QrCodeParser.validateQrUrl("https://www.yuketang.cn.evil.com/x?c=1", account: prodAccount, profile: profile))
        XCTAssertFalse(QrCodeParser.validateQrUrl("https://www.yuketang.cn@evil.example/x?c=1", account: prodAccount, profile: profile))
        XCTAssertFalse(QrCodeParser.validateQrUrl("https://www.yuketang.cn\\@evil.example/x?c=1", account: prodAccount, profile: profile))
        XCTAssertFalse(QrCodeParser.validateQrUrl("https://evil.example/x?c=1", accountHost: "www.yuketang.cn", profile: profile))

        // 阻断：HTTPS 降级为明文 HTTP、非允许端口
        XCTAssertFalse(QrCodeParser.validateQrUrl("http://www.yuketang.cn/api/v3/lesson/checkin?c=1", account: prodAccount, profile: profile))
        XCTAssertFalse(QrCodeParser.validateQrUrl("https://www.yuketang.cn:9999/x?c=1", account: prodAccount, profile: profile))

        // 阻断：非 http/https 协议与无协议输入
        XCTAssertFalse(QrCodeParser.validateQrUrl("app://yuketang/checkin?c=1", account: prodAccount, profile: profile))
        XCTAssertFalse(QrCodeParser.validateQrUrl("javascript://www.yuketang.cn/%0aalert(1)", account: prodAccount, profile: profile))
        XCTAssertFalse(QrCodeParser.validateQrUrl("file:///etc/passwd", account: prodAccount, profile: profile))
        XCTAssertFalse(QrCodeParser.validateQrUrl("ftp://www.yuketang.cn/checkin?c=1", account: prodAccount, profile: profile))
        XCTAssertFalse(QrCodeParser.validateQrUrl("www.yuketang.cn/no-scheme", account: prodAccount, profile: profile))
    }

    // MARK: - CredentialSanitizer, Masking & TemplateRenderer

    func testCredentialSanitizerCleanBearerCookieAndHost() {
        // Bearer 清洗
        XCTAssertEqual(CredentialSanitizer.cleanBearer("Bearer abc.def.ghi"), "abc.def.ghi")
        XCTAssertEqual(CredentialSanitizer.cleanBearer("Authorization: Bearer   \"tok-123\" "), "tok-123")
        XCTAssertEqual(CredentialSanitizer.cleanBearer("set-auth: bearer bearer tok-456\r\n"), "tok-456")
        XCTAssertNil(CredentialSanitizer.cleanBearer("   \n\t "))
        XCTAssertNil(CredentialSanitizer.cleanBearer("Bearer   "))

        // Cookie 清洗
        let cookieHeader = "Cookie: csrftoken=csrf123; sessionid=sid987; Path=/"
        XCTAssertEqual(CredentialSanitizer.cleanCookieValue(cookieHeader, key: "sessionid"), "sid987")
        XCTAssertEqual(CredentialSanitizer.cleanCookieValue(cookieHeader, key: "csrftoken"), "csrf123")
        XCTAssertEqual(
            CredentialSanitizer.cleanCookieValue("Set-Cookie: sid=alt-sid-1; HttpOnly; Path=/", key: "sessionid"),
            "alt-sid-1"
        )
        XCTAssertNil(CredentialSanitizer.cleanCookieValue("Set-Cookie: sessionid=deleted; Path=/", key: "sessionid"))
        XCTAssertEqual(CredentialSanitizer.cleanCookieValue("raw-sid-value", key: "sessionid"), "raw-sid-value")
        XCTAssertNil(CredentialSanitizer.cleanCookieValue("csrftoken=only-csrf", key: "sessionid"))
        XCTAssertNil(CredentialSanitizer.cleanCookieValue("   ", key: "sessionid"))

        // Host 清洗
        let h1 = CredentialSanitizer.cleanHost("https://Pro.YuKeTang.CN/v2/web/index?foo=1#top")
        XCTAssertEqual(h1.host, "pro.yuketang.cn")
        XCTAssertEqual(h1.scheme, "https")

        let h2 = CredentialSanitizer.cleanHost("http://127.0.0.1:8787/api/v3/lesson/checkin")
        XCTAssertEqual(h2.host, "127.0.0.1:8787")
        XCTAssertEqual(h2.scheme, "http")

        let h3 = CredentialSanitizer.cleanHost("  changjiang.yuketang.cn/v2/web/studentLog/1 ")
        XCTAssertEqual(h3.host, "changjiang.yuketang.cn")
        XCTAssertNil(h3.scheme)

        let h4 = CredentialSanitizer.cleanHost("   ")
        XCTAssertEqual(h4.host, "")
        XCTAssertNil(h4.scheme)
    }

    func testAccountMaskedCredentialAndTemplateRenderer() {
        let emptyAcc = Account(id: "0", label: "空")
        XCTAssertEqual(emptyAcc.maskedCredential(), "未配置")

        let shortAcc = Account(id: "1", label: "短", bearer: "123456789012")
        XCTAssertEqual(shortAcc.maskedCredential(), "****")

        let medAcc = Account(id: "2", label: "中", bearer: "1234567890123456")
        XCTAssertEqual(medAcc.maskedCredential(), "12…56")

        let longAcc = Account(id: "3", label: "长", bearer: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9")
        XCTAssertEqual(longAcc.maskedCredential(), "eyJh…CJ9")

        // TemplateRenderer 路径安全编码与数组内浮点数值保留
        let vars: [String: TemplateValue] = [
            "lessonId": .string("123/../../admin?x=1"),
            "lat": .double(39.99125),
            "tag": .string("ok")
        ]
        let safePath = TemplateRenderer.renderPath("/api/v3/lesson/{lessonId}/info", variables: vars)
        XCTAssertFalse(safePath.contains("../"))
        XCTAssertFalse(safePath.contains("?x=1"))
        XCTAssertTrue(safePath.contains("%2F"))

        let bodyTemplate: [String: TemplateValue] = [
            "coords": .array([.string("{lat}")]),
            "nested": .array([.object(["label": .string("prefix-{tag}")])])
        ]
        let rendered = TemplateRenderer.renderBody(bodyTemplate, variables: vars)
        if let coordsValue = rendered["coords"],
           case .array(let coords) = coordsValue,
           let firstCoord = coords.first,
           case .double(let lat) = firstCoord {
            XCTAssertEqual(lat, 39.99125, accuracy: 0.000001)
        } else {
            XCTFail("coords[0] 必须保留 double 数值类型")
        }
        XCTAssertEqual(rendered["nested"]?.arrayValue?.first?.objectValue?["label"]?.stringValue, "prefix-ok")
    }
}
