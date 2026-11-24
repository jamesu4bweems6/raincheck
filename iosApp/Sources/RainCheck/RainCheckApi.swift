//
//  RainCheckApi.swift
//  RainCheck
//
//  雨课堂 HTTP 客户端，与 `core/src/commonMain/kotlin/cn/raincheck/core/Api.kt` 100% 对齐：
//   - `JSONAssist.int` 显式排除 `CFBoolean`，杜绝 `false == 0` 误判成功；
//   - `JSONAssist.string` 绝不把 Dictionary / Array 转成调试字符串；
//   - 严格按 `profile.auth` 配置（`bearerHeader`/`bearerPrefix`/`cookieNames`/`csrfCookie`/`csrfHeader`）发包；
//   - 响应头吸收优先使用 `HTTPCookie.cookies(withResponseHeaderFields:for:)`，忽略过期/空值清 Cookie，
//     `tokenResponseHeaders` 严格按顺序（`set-auth` 优先于 `authorization`），且仅在 HTTP 2xx/3xx 吸收；
//   - 完整兼容 `code`/`errcode` 与 `msg`/`message`/`errmsg`。
//

import Foundation

// MARK: - JSON 取值辅助（兼顾 Any 与 Sendable JSONValue）

enum JSONAssist {
    /// 安全提取字符串：显式排除 NSNull 与集合类型（Dict/Array 绝不转调试串）。
    static func string(_ value: Any?) -> String? {
        guard let value else { return nil }
        if value is NSNull { return nil }
        if let json = value as? JSONValue {
            return json.nonNullScalarString
        }
        if let text = value as? String {
            return text
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        }
        return nil
    }

    /// 安全提取整数：先排除 `CFBoolean`（`CFGetTypeID(num) != CFBooleanGetTypeID()`），
    /// 彻底修复 `JSONAssist.int(false) == 0` 的致命误判。
    static func int(_ value: Any?) -> Int? {
        guard let value else { return nil }
        if value is NSNull { return nil }
        if let json = value as? JSONValue {
            return json.nonNullInt
        }
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else {
                return nil
            }
            return number.intValue
        }
        if let text = value as? String {
            return Int(text.trimmed)
        }
        return nil
    }

    static func bool(_ value: Any?) -> Bool? {
        guard let value else { return nil }
        if value is NSNull { return nil }
        if let json = value as? JSONValue {
            return json.nonNullBool
        }
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue
        }
        if let text = value as? String {
            switch text.trimmed.lowercased() {
            case "true": return true
            case "false": return false
            default: return nil
            }
        }
        return nil
    }

    static func firstString(_ dict: [String: JSONValue], _ keys: [String]) -> String? {
        for key in keys {
            if let text = dict[key]?.nonNullScalarString?.trimmedNonEmpty {
                return text
            }
        }
        return nil
    }

    static func firstInt(_ dict: [String: JSONValue], _ keys: [String]) -> Int? {
        for key in keys {
            if let number = dict[key]?.nonNullInt {
                return number
            }
        }
        return nil
    }
}

/// RFC3986 最小安全字符集，避免 `+ & =` 在 query 里被误解析。
enum PercentEncoder {
    private static let allowed: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return set
    }()

    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

// MARK: - RainCheckApi

final class RainCheckApi: @unchecked Sendable {
    let profile: ProtocolProfile
    private let session: URLSession

    init(profile: ProtocolProfile, session: URLSession? = nil) {
        self.profile = profile
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 25
            configuration.timeoutIntervalForResource = 30
            // 禁止共享系统 Cookie，完全由双载体账号池精确控制
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    func close() {
        session.finishTasksAndInvalidate()
    }

    // MARK: 业务入口

    func call(
        account: Account,
        endpointName: String,
        vars: [String: JSONValue] = [:],
        referer: String? = nil,
        extraHeaders: [String: String] = [:]
    ) async -> ApiResult {
        guard let endpoint = profile.endpoints[endpointName] else {
            return ApiResult(httpStatus: -2, body: "profile 缺少 endpoint: \(endpointName)", ok: false)
        }
        let base = baseUrl(account: account)
        let path = Template.renderPath(endpoint.path, vars: vars)
        let query = Template.renderMap(endpoint.query, vars: vars)
        let url = buildUrl(base: base, path: path, query: query)
        let body = endpoint.body.map { Template.renderBody($0, vars: vars) }
        let authorized: Account? = endpoint.auth ? account : nil
        return await execute(
            account: authorized,
            method: endpoint.method,
            url: url,
            body: body,
            referer: referer,
            extraHeaders: extraHeaders
        )
    }

    func raw(
        account: Account?,
        method: String,
        url: String,
        body: JSONValue? = nil,
        referer: String? = nil,
        extraHeaders: [String: String] = [:]
    ) async -> ApiResult {
        await execute(
            account: account,
            method: method,
            url: url,
            body: body,
            referer: referer,
            extraHeaders: extraHeaders
        )
    }

    // MARK: URL 构造

    func baseUrl(account: Account) -> String {
        "\(account.scheme)://\(account.host)"
    }

    func baseUrl(edition: Edition) -> String {
        "\(edition.scheme)://\(edition.host)"
    }

    func buildUrl(base: String, path: String, query: [String: String]) -> String {
        let normalizedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        let normalizedPath: String
        if path.isEmpty {
            normalizedPath = ""
        } else if path.hasPrefix("/") {
            normalizedPath = path
        } else {
            normalizedPath = "/" + path
        }
        let pairs = query
            .filter { !$0.key.trimmed.isEmpty && !$0.value.trimmed.isEmpty }
            .sorted { $0.key < $1.key }
            .map { "\(PercentEncoder.encode($0.key))=\(PercentEncoder.encode($0.value))" }
        let queryString = pairs.joined(separator: "&")
        if queryString.isEmpty {
            return normalizedBase + normalizedPath
        }
        let separator: String
        if !normalizedPath.contains("?") {
            separator = "?"
        } else if normalizedPath.hasSuffix("?") || normalizedPath.hasSuffix("&") {
            separator = ""
        } else {
            separator = "&"
        }
        return normalizedBase + normalizedPath + separator + queryString
    }

    static func referer(account: Account, classroomId: String?) -> String {
        let base = "\(account.scheme)://\(account.host)"
        if let classroomId = classroomId?.trimmedNonEmpty {
            return "\(base)/v2/web/studentLog/\(classroomId)"
        }
        return "\(base)/v2/web/index"
    }

    // MARK: 内部执行

    private func execute(
        account: Account?,
        method: String,
        url: String,
        body: JSONValue?,
        referer: String?,
        extraHeaders: [String: String]
    ) async -> ApiResult {
        let started = TimeUtil.nowMillis()

        guard let requestUrl = URL(string: url) else {
            return ApiResult(
                httpStatus: -1,
                body: "URL 不合法: \(url)",
                elapsedMs: TimeUtil.nowMillis() - started,
                ok: false
            )
        }

        var request = URLRequest(url: requestUrl)
        request.httpMethod = method.uppercased()
        if let userAgent = profile.userAgent.trimmedNonEmpty {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        for (key, value) in profile.headers {
            if !(body != nil && key.caseInsensitiveCompare("Content-Type") == .orderedSame) {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        if let account {
            applyAuth(account, to: &request)
        }
        if let referer = referer?.trimmedNonEmpty {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
        for (key, value) in extraHeaders {
            if !(body != nil && key.caseInsensitiveCompare("Content-Type") == .orderedSame) {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        if let body {
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.serialized().utf8)
        }

        let payload: (Data, URLResponse)
        do {
            payload = try await session.data(for: request)
        } catch {
            return ApiResult(
                httpStatus: -1,
                body: error.localizedDescription,
                elapsedMs: TimeUtil.nowMillis() - started,
                ok: false
            )
        }

        let data = payload.0
        let httpResponse = payload.1 as? HTTPURLResponse
        let httpStatus = httpResponse?.statusCode ?? -1
        let text = String(data: data, encoding: .utf8) ?? ""

        let parsedRoot = try? JSONDecoder().decode(JSONValue.self, from: data)
        let jsonObject = parsedRoot?.objectValue

        let code = jsonObject.flatMap { JSONAssist.firstInt($0, profile.result.allCodeKeys) }
        let message = jsonObject.flatMap { JSONAssist.firstString($0, profile.result.allMessageKeys) }
        let auth = (200...399).contains(httpStatus)
            ? extractAuth(response: httpResponse, requestUrl: requestUrl, account: account)
            : nil
        let businessOk = (200...299).contains(httpStatus) && profile.result.isOkCode(code)

        return ApiResult(
            httpStatus: httpStatus,
            body: text,
            json: jsonObject,
            code: code,
            message: message,
            elapsedMs: TimeUtil.nowMillis() - started,
            auth: auth,
            ok: businessOk
        )
    }

    /// 双载体鉴权：严格遵循 `profile.auth` 定义的 header/prefix/cookieNames/csrfCookie。
    private func applyAuth(_ account: Account, to request: inout URLRequest) {
        if let rawBearer = account.bearer?.trimmedNonEmpty {
            let bare = stripBearerPrefix(rawBearer)
            if !bare.isEmpty {
                request.setValue(profile.auth.bearerPrefix + bare, forHTTPHeaderField: profile.auth.bearerHeader)
            }
        }

        let sessionName = profile.auth.primarySessionCookie
        let csrfName = profile.auth.effectiveCsrfCookie
        var cookies: [String] = []
        if let sessionId = account.sessionId?.trimmedNonEmpty {
            cookies.append("\(sessionName)=\(sessionId)")
        }
        if let csrfToken = account.csrfToken?.trimmedNonEmpty {
            cookies.append("\(csrfName)=\(csrfToken)")
        }
        if !cookies.isEmpty {
            request.setValue(cookies.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        }
        if let csrfToken = account.csrfToken?.trimmedNonEmpty {
            request.setValue(csrfToken, forHTTPHeaderField: profile.auth.csrfHeader)
        }
    }

    /// 吸收 `tokenResponseHeaders`（按配置顺序取首个非空，确保 `set-auth` 优先于 `authorization`）与 `Set-Cookie`。
    func extractAuth(response: HTTPURLResponse?, requestUrl: URL, account: Account?) -> AuthUpdate? {
        guard let response else { return nil }
        let rawHeaders = response.allHeaderFields

        var bearer: String?
        for headerName in profile.auth.tokenResponseHeaders {
            if let value = headerValues(rawHeaders, name: headerName).first {
                let cleaned = stripBearerPrefix(value)
                if !cleaned.isEmpty {
                    bearer = cleaned
                    break
                }
            }
        }

        let csrfCookieName = profile.auth.effectiveCsrfCookie
        let sessionCookieNames = profile.auth.acceptedSessionCookies

        var sessionId: String?
        var csrf: String?

        // 优先使用 Foundation 的 HTTPCookie 解析（正确处理 Expires 里的英文逗号、属性与过期时间）
        var stringHeaders: [String: String] = [:]
        for (key, value) in rawHeaders {
            if let k = key as? String, let v = JSONAssist.string(value) {
                stringHeaders[k] = v
            }
        }
        let now = Date()
        let parsedCookies = HTTPCookie.cookies(withResponseHeaderFields: stringHeaders, for: requestUrl)
        for cookie in parsedCookies {
            let value = cookie.value.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if value.isEmpty || value.caseInsensitiveCompare("deleted") == .orderedSame {
                continue
            }
            if let expires = cookie.expiresDate, expires <= now {
                continue
            }
            if cookie.name.caseInsensitiveCompare(csrfCookieName) == .orderedSame {
                csrf = value
            } else if sessionCookieNames.contains(where: { $0.caseInsensitiveCompare(cookie.name) == .orderedSame }) {
                sessionId = value
            }
        }

        let effectiveBearer = bearer.flatMap { $0 != account?.bearer ? $0 : nil }
        let effectiveSession = sessionId.flatMap { $0 != account?.sessionId ? $0 : nil }
        let effectiveCsrf = csrf.flatMap { $0 != account?.csrfToken ? $0 : nil }
        if effectiveBearer == nil && effectiveSession == nil && effectiveCsrf == nil {
            return nil
        }
        return AuthUpdate(bearer: effectiveBearer, sessionId: effectiveSession, csrfToken: effectiveCsrf)
    }

    private func stripBearerPrefix(_ raw: String) -> String {
        let trimmed = raw.trimmed
        let prefix = profile.auth.bearerPrefix
        if !prefix.isEmpty && trimmed.lowercased().hasPrefix(prefix.lowercased()) {
            return String(trimmed.dropFirst(prefix.count)).trimmed
        }
        let trimmedPrefix = prefix.trimmed
        if !trimmedPrefix.isEmpty && trimmed.lowercased().hasPrefix((trimmedPrefix + " ").lowercased()) {
            return String(trimmed.dropFirst(trimmedPrefix.count + 1)).trimmed
        }
        return trimmed
    }

    private func headerValues(_ headers: [AnyHashable: Any], name: String) -> [String] {
        var out: [String] = []
        for (key, value) in headers {
            guard let keyName = key as? String else { continue }
            if keyName.caseInsensitiveCompare(name) == .orderedSame,
               let text = JSONAssist.string(value)?.trimmedNonEmpty {
                out.append(text)
            }
        }
        return out
    }
}
