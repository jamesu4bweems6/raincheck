//
//  TestSupport.swift
//  RainCheckTests
//
//  XCTest 通用夹具：线程安全 MockURLProtocol、协议资源加载器与测试账号工厂。
//

import Foundation
import XCTest
@testable import RainCheck

struct CapturedHTTPRequest: Sendable {
    let method: String
    let url: String
    let headers: [String: String]
    let body: String
}

struct MockHTTPResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data

    init(
        statusCode: Int = 200,
        headers: [String: String] = ["Content-Type": "application/json"],
        jsonText: String
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = Data(jsonText.utf8)
    }

    init(
        statusCode: Int = 200,
        headers: [String: String] = ["Content-Type": "text/plain"],
        text: String
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = Data(text.utf8)
    }
}

/// 线程安全路由中心（支持并发测试与严格 Swift 6 并发模式）。
final class MockTransportBox: @unchecked Sendable {
    static let shared = MockTransportBox()

    private let lock = NSLock()
    private var handlers: [String: @Sendable (CapturedHTTPRequest) throws -> MockHTTPResponse] = [:]
    private var logs: [String: [CapturedHTTPRequest]] = [:]

    func register(
        id: String,
        handler: @escaping @Sendable (CapturedHTTPRequest) throws -> MockHTTPResponse
    ) {
        lock.lock()
        defer { lock.unlock() }
        handlers[id] = handler
        logs[id] = []
    }

    func unregister(id: String) {
        lock.lock()
        defer { lock.unlock() }
        handlers.removeValue(forKey: id)
        logs.removeValue(forKey: id)
    }

    func requests(for id: String) -> [CapturedHTTPRequest] {
        lock.lock()
        defer { lock.unlock() }
        return logs[id] ?? []
    }

    func dispatch(id: String, request: CapturedHTTPRequest) throws -> MockHTTPResponse {
        lock.lock()
        logs[id, default: []].append(request)
        let handler = handlers[id]
        lock.unlock()
        guard let handler else {
            throw URLError(.cannotConnectToHost)
        }
        return try handler(request)
    }
}

final class MockURLProtocol: URLProtocol {
    static let routerHeader = "X-RainCheck-Test-Router"

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let routerId = request.value(forHTTPHeaderField: MockURLProtocol.routerHeader) ?? ""
        let bodyData = readRequestBody(from: request)
        let bodyString = String(data: bodyData, encoding: .utf8) ?? ""
        var headers = request.allHTTPHeaderFields ?? [:]
        headers.removeValue(forKey: MockURLProtocol.routerHeader)

        let captured = CapturedHTTPRequest(
            method: request.httpMethod ?? "GET",
            url: request.url?.absoluteString ?? "",
            headers: headers,
            body: bodyString
        )

        do {
            let reply = try MockTransportBox.shared.dispatch(id: routerId, request: captured)
            guard let url = request.url,
                  let httpResponse = HTTPURLResponse(
                      url: url,
                      statusCode: reply.statusCode,
                      httpVersion: "HTTP/1.1",
                      headerFields: reply.headers
                  ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private func readRequestBody(from request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return Data()
        }
        stream.open()
        defer { stream.close() }
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count > 0 {
                out.append(buffer, count: count)
            } else {
                break
            }
        }
        return out
    }
}

enum TestFixtures {
    private final class BundleToken {}

    static var testBundle: Bundle {
        Bundle(for: BundleToken.self)
    }

    static func loadProtocolProfile(file: StaticString = #filePath, line: UInt = #line) throws -> ProtocolProfile {
        if let url = testBundle.url(forResource: "profile", withExtension: "json") {
            let data = try Data(contentsOf: url)
            return try ProtocolProfile.parse(data: data)
        }
        if let url = Bundle.main.url(forResource: "protocol_profile", withExtension: "json") {
            let data = try Data(contentsOf: url)
            return try ProtocolProfile.parse(data: data)
        }
        XCTFail("未在测试 Bundle 中找到 profile.json", file: file, line: line)
        return ProfileStore.fallbackProfile()
    }

    static func loadQrCasesData(file: StaticString = #filePath, line: UInt = #line) throws -> Data {
        if let url = testBundle.url(forResource: "qr_cases", withExtension: "json") {
            return try Data(contentsOf: url)
        }
        XCTFail("未在测试 Bundle 中找到 qr_cases.json", file: file, line: line)
        return Data()
    }

    static func makeMockApi(
        profile: ProtocolProfile,
        routerId: String,
        handler: @escaping @Sendable (CapturedHTTPRequest) throws -> MockHTTPResponse
    ) -> RainCheckApi {
        MockTransportBox.shared.register(id: routerId, handler: handler)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.httpAdditionalHeaders = [MockURLProtocol.routerHeader: routerId]
        let session = URLSession(configuration: config)
        return RainCheckApi(profile: profile, session: session)
    }

    static func sampleAccount(
        id: String = "acc-1",
        label: String = "测试账号",
        host: String = "www.yuketang.cn",
        scheme: String = "https",
        bearer: String? = "tok_super_secret_bearer_token_9999",
        sessionId: String? = "sid_super_secret_session_8888",
        csrfToken: String? = "csrf_super_secret_7777",
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
}
