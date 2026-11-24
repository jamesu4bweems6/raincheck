//
//  QrParserTests.swift
//  RainCheckTests
//
//  加载并断言全部 `protocol/vectors/qr_cases.json` 跨端向量，
//  同时覆盖边界条件与域名白名单安全校验。
//

import Foundation
import XCTest
@testable import RainCheck

final class QrParserTests: XCTestCase {
    private struct QrVectorFile: Decodable {
        let version: Int
        let cases: [QrVectorCase]
    }

    private struct QrVectorCase: Decodable {
        let name: String
        let raw: String
        let expect: QrVectorExpect
    }

    private struct QrVectorExpect: Decodable {
        let kind: String
        let host: String?
        let lessonId: String?
        let classroomId: String?
        let checkinId: String?
        let params: [String: String]?
    }

    func testAllProtocolVectorCasesPass() throws {
        let profile = try TestFixtures.loadProtocolProfile()
        let data = try TestFixtures.loadQrCasesData()
        let vectors = try JSONDecoder().decode(QrVectorFile.self, from: data)

        XCTAssertGreaterThanOrEqual(vectors.cases.count, 20, "qr_cases.json 应至少包含 20 条跨端向量")

        for item in vectors.cases {
            let parsed = QrParser.parse(item.raw, profile: profile)
            XCTAssertEqual(parsed.kind.rawValue, item.expect.kind, "用例失败 [\(item.name)] kind")

            if let expectedHost = item.expect.host {
                XCTAssertEqual(parsed.host, expectedHost, "用例失败 [\(item.name)] host")
            }
            if let expectedLesson = item.expect.lessonId {
                XCTAssertEqual(parsed.lessonId, expectedLesson, "用例失败 [\(item.name)] lessonId")
            }
            if let expectedClassroom = item.expect.classroomId {
                XCTAssertEqual(parsed.classroomId, expectedClassroom, "用例失败 [\(item.name)] classroomId")
            }
            if let expectedCheckin = item.expect.checkinId {
                XCTAssertEqual(parsed.checkinId, expectedCheckin, "用例失败 [\(item.name)] checkinId")
            }
            if let expectedParams = item.expect.params {
                for (key, expectedValue) in expectedParams {
                    XCTAssertEqual(
                        parsed.params[key],
                        expectedValue,
                        "用例失败 [\(item.name)] param[\(key)]"
                    )
                }
            }
        }
    }

    func testTrimLeadingPreservesTrailingQuestionMarkInSignature() throws {
        let profile = try TestFixtures.loadProtocolProfile()
        let ticket = QrParser.parse("?c=code01&t=1763900000&s=sigval?", profile: profile)
        XCTAssertEqual(ticket.kind, .DYNAMIC_CHECKIN)
        XCTAssertEqual(ticket.dynamicCode, "code01")
        XCTAssertEqual(ticket.signature, "sigval?")
    }

    func testDynamicKeysDrivenByProfileSpec() {
        var profile = ProfileStore.fallbackProfile()
        profile.qr.dynamicKeys = ["code", "ts"]
        let ticket = QrParser.parse("https://www.yuketang.cn/checkin?code=abc&ts=123", profile: profile)
        XCTAssertEqual(ticket.kind, .DYNAMIC_CHECKIN)
    }

    func testValidateQrUrlEnforcesWhitelistAndScheme() throws {
        let profile = try TestFixtures.loadProtocolProfile()
        let account = TestFixtures.sampleAccount(host: "www.yuketang.cn", scheme: "https")

        // 白名单 HTTPS 放行（含默认 :443）
        XCTAssertNil(profile.validateQrUrl("https://www.yuketang.cn/api/v3/lesson/checkin?c=1", account: account))
        XCTAssertNil(profile.validateQrUrl("https://pro.yuketang.cn:443/checkin?c=1", account: account))
        XCTAssertNil(profile.validateQrUrl("https://www.xuetangx.com/checkin?c=1", account: account))

        // 内置 mock 明文 HTTP 放行
        XCTAssertNil(profile.validateQrUrl("http://127.0.0.1:8787/api/v3/lesson/checkin?c=1", account: account))

        // 恶意第三方域名拦截
        XCTAssertNotNil(profile.validateQrUrl("https://evil.example/steal?c=1&t=2&s=3", account: account))
        // 非显式白名单明文 HTTP 拦截（即便域名是 www.yuketang.cn）
        XCTAssertNotNil(profile.validateQrUrl("http://www.yuketang.cn/api/v3/lesson/checkin?c=1", account: account))
        // 包含 userinfo `@` 或非法 scheme 拦截
        XCTAssertNotNil(profile.validateQrUrl("https://www.yuketang.cn@evil.example/checkin", account: account))
        XCTAssertNotNil(profile.validateQrUrl("app://yuketang/checkin?c=1", account: account))
    }

    func testBundledProfileAndFallbackProfileParity() throws {
        let bundled = try TestFixtures.loadProtocolProfile()
        let fallback = ProfileStore.fallbackProfile()

        XCTAssertEqual(bundled.editions.map(\.id), fallback.editions.map(\.id))
        XCTAssertEqual(bundled.edition(id: "tsinghua")?.host, "pro.yuketang.cn")
        XCTAssertEqual(fallback.edition(id: "tsinghua")?.host, "pro.yuketang.cn")
        XCTAssertEqual(Set(bundled.endpoints.keys), Set(fallback.endpoints.keys))
        XCTAssertEqual(bundled.strategies.map(\.id), fallback.strategies.map(\.id))
    }
}
