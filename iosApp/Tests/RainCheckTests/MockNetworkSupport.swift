import Foundation
import XCTest
@testable import RainCheck

/// 线程安全的可变状态容器，用于在 `@Sendable` Mock 回调中记录断言状态（满足 `SWIFT_STRICT_CONCURRENCY: complete`）。
final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ initialValue: Value) {
        self.value = initialValue
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }

    @discardableResult
    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

/// 不可变、并发安全的模拟 HTTP 响应模型。
struct MockHTTPResponse: Sendable {
    let statusCode: Int
    let body: Data
    let headers: [String: String]

    init(statusCode: Int, body: Data, headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.body = body
        self.headers = headers
    }

    static func json(
        _ statusCode: Int,
        _ body: String,
        headers: [String: String] = [:]
    ) -> MockHTTPResponse {
        var merged = headers
        let hasContentType = merged.keys.contains { $0.caseInsensitiveCompare("Content-Type") == .orderedSame }
        if !hasContentType {
            merged["Content-Type"] = "application/json; charset=utf-8"
        }
        return MockHTTPResponse(
            statusCode: statusCode,
            body: Data(body.utf8),
            headers: merged
        )
    }

    static func text(
        _ statusCode: Int,
        _ body: String,
        contentType: String = "text/plain; charset=utf-8",
        headers: [String: String] = [:]
    ) -> MockHTTPResponse {
        var merged = headers
        merged["Content-Type"] = contentType
        return MockHTTPResponse(
            statusCode: statusCode,
            body: Data(body.utf8),
            headers: merged
        )
    }
}

/// 线程安全（`NSLock` + `@unchecked Sendable`）的 `URLProtocol` 拦截器，零全局可变 `static var`。
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias RequestHandler = @Sendable (URLRequest) throws -> MockHTTPResponse

    private final class HandlerStore: @unchecked Sendable {
        private let lock = NSLock()
        private var handler: RequestHandler?

        func set(_ newHandler: RequestHandler?) {
            lock.lock()
            defer { lock.unlock() }
            handler = newHandler
        }

        func get() -> RequestHandler? {
            lock.lock()
            defer { lock.unlock() }
            return handler
        }
    }

    private static let store = HandlerStore()

    static func setHandler(_ handler: RequestHandler?) {
        store.set(handler)
    }

    static func reset() {
        store.set(nil)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.store.get() else {
            let error = NSError(
                domain: "RainCheckTests.MockURLProtocol",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "MockURLProtocol handler 未注册"]
            )
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        do {
            let mock = try handler(request)
            let url = request.url ?? URL(string: "https://www.yuketang.cn")!
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: mock.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: mock.headers
            ) else {
                throw NSError(
                    domain: "RainCheckTests.MockURLProtocol",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "无法构造 HTTPURLResponse"]
                )
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: mock.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// 单元测试网络工厂与请求检查工具。
enum MockNetworkSupport {
    /// 创建注入 `MockURLProtocol` 的隔离 `URLSession`（禁用共享 Cookie 池与磁盘缓存）。
    static func makeSession(
        handler: @escaping @Sendable (URLRequest) throws -> MockHTTPResponse
    ) -> URLSession {
        MockURLProtocol.setHandler(handler)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: config)
    }

    /// 完整读取请求体字节，兼容 `URLSession` 在 `URLProtocol` 中将 `httpBody` 转换为 `httpBodyStream` 的行为。
    static func requestBodyData(from request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return Data()
        }
        stream.open()
        defer { stream.close() }

        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let bytesRead = stream.read(&buffer, maxLength: buffer.count)
            if bytesRead > 0 {
                collected.append(buffer, count: bytesRead)
            } else {
                break
            }
        }
        return collected
    }

    static func requestBodyString(from request: URLRequest) -> String {
        String(data: requestBodyData(from: request), encoding: .utf8) ?? ""
    }

    static func requestBodyJSON(from request: URLRequest) -> [String: TemplateValue]? {
        RainCheckClient.parseJSONObject(from: requestBodyData(from: request))
    }

    static func headerValue(_ name: String, in request: URLRequest) -> String? {
        guard let fields = request.allHTTPHeaderFields else { return nil }
        for (key, value) in fields where key.caseInsensitiveCompare(name) == .orderedSame {
            return value
        }
        return nil
    }
}

/// 跨端 `protocol/vectors/qr_cases.json` 向量模型。
struct QrVectorFile: Decodable, Sendable {
    let version: Int
    let cases: [QrVectorCase]
}

struct QrVectorCase: Decodable, Sendable {
    let name: String
    let raw: String
    let expect: QrVectorExpect
}

struct QrVectorExpect: Decodable, Sendable {
    let kind: String
    let host: String?
    let lessonId: String?
    let classroomId: String?
    let checkinId: String?
    let params: [String: String]?
}

/// 测试包资源加载器（优先从 `Bundle(for: ...)` 加载 XcodeGen 打包的 `qr_cases.json` 与 `profile.json`）。
enum TestBundleResources {
    private final class BundleAnchor {}

    static var testBundle: Bundle {
        Bundle(for: BundleAnchor.self)
    }

    static func loadResourceData(
        name: String,
        withExtension ext: String = "json",
        subdirectories: [String?] = [nil, "vectors"],
        fallbackProtocolRelativePath: String? = nil
    ) throws -> Data {
        for subdir in subdirectories {
            if let url = testBundle.url(forResource: name, withExtension: ext, subdirectory: subdir) {
                return try Data(contentsOf: url)
            }
        }

        if let fallbackProtocolRelativePath {
            let sourceFileURL = URL(fileURLWithPath: #filePath)
            // Tests/RainCheckTests/MockNetworkSupport.swift -> iosApp -> raincheck -> protocol/...
            let raincheckRoot = sourceFileURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let candidate = raincheckRoot
                .appendingPathComponent("protocol", isDirectory: true)
                .appendingPathComponent(fallbackProtocolRelativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try Data(contentsOf: candidate)
            }
        }

        throw NSError(
            domain: "RainCheckTests.TestBundleResources",
            code: 404,
            userInfo: [NSLocalizedDescriptionKey: "测试包中缺少资源文件 \(name).\(ext)"]
        )
    }

    static func loadProtocolProfile() throws -> ProtocolProfile {
        let data = try loadResourceData(
            name: "profile",
            withExtension: "json",
            subdirectories: [nil],
            fallbackProtocolRelativePath: "profile.json"
        )
        return try ProtocolCatalog.load(from: data)
    }

    static func loadQrVectorFile() throws -> QrVectorFile {
        let data = try loadResourceData(
            name: "qr_cases",
            withExtension: "json",
            subdirectories: [nil, "vectors"],
            fallbackProtocolRelativePath: "vectors/qr_cases.json"
        )
        return try JSONDecoder().decode(QrVectorFile.self, from: data)
    }
}
