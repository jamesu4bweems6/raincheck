import Foundation

/// 服务端响应回填的会话凭据增量（`set-auth` / `authorization` / `Set-Cookie`）。
struct AuthUpdate: Equatable, Sendable {
    let bearer: String?
    let sessionId: String?
    let csrfToken: String?

    init(bearer: String? = nil, sessionId: String? = nil, csrfToken: String? = nil) {
        self.bearer = bearer
        self.sessionId = sessionId
        self.csrfToken = csrfToken
    }

    var isEmpty: Bool {
        let bEmpty = bearer?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        let sEmpty = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        let cEmpty = csrfToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        return bEmpty && sEmpty && cEmpty
    }

    func apply(to account: Account, markOk: Bool = false) -> Account {
        var updated = account
        if let bearer, !bearer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updated.bearer = bearer
        }
        if let sessionId, !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updated.sessionId = sessionId
        }
        if let csrfToken, !csrfToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updated.csrfToken = csrfToken
        }
        if markOk {
            updated.lastOkAt = RainCheckTime.nowMillis()
        }
        return updated
    }
}

/// 统一的 HTTP / 协议响应视图。
struct ApiCallResult: Sendable {
    let httpStatus: Int
    let bodyText: String
    let jsonObject: [String: TemplateValue]?
    let businessCode: Int?
    let message: String?
    let elapsedMs: Int64
    let authUpdate: AuthUpdate?
    let responseCookies: [String: String]
    let ok: Bool
    let requestMethod: String
    let requestUrl: String
    let isTimeout: Bool
    let isCancelled: Bool

    init(
        httpStatus: Int,
        bodyText: String,
        jsonObject: [String: TemplateValue]?,
        businessCode: Int?,
        message: String?,
        elapsedMs: Int64,
        authUpdate: AuthUpdate?,
        responseCookies: [String: String],
        ok: Bool,
        requestMethod: String,
        requestUrl: String,
        isTimeout: Bool = false,
        isCancelled: Bool = false
    ) {
        self.httpStatus = httpStatus
        self.bodyText = bodyText
        self.jsonObject = jsonObject
        self.businessCode = businessCode
        self.message = message
        self.elapsedMs = elapsedMs
        self.authUpdate = authUpdate
        self.responseCookies = responseCookies
        self.ok = ok
        self.requestMethod = requestMethod
        self.requestUrl = requestUrl
        self.isTimeout = isTimeout
        self.isCancelled = isCancelled
    }

    var dataObject: [String: TemplateValue]? {
        jsonObject?["data"]?.objectValue
    }

    func dataValue(_ key: String) -> TemplateValue? {
        dataObject?[key]
    }

    func firstNonBlankDataString(_ keys: String...) -> String? {
        dataObject?.firstNonBlankString(keys)
    }
}

/// `/api/v3/user/basic-info` 验证通过后的用户画像。
struct VerifiedProfile: Equatable, Sendable {
    let userId: String?
    let name: String?
    let refreshedAccount: Account?
}

enum RainCheckClientError: Error, LocalizedError, Sendable {
    case unknownEndpoint(String)
    case invalidURL(String)
    case networkError(String)
    case authFailed(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .unknownEndpoint(let name):
            return "协议配置缺少接口定义: \(name)"
        case .invalidURL(let url):
            return "无效的请求地址: \(url)"
        case .networkError(let detail):
            return "网络请求异常: \(detail)"
        case .authFailed(let detail):
            return detail
        case .invalidResponse(let detail):
            return detail
        }
    }
}

/// 纯 Foundation 网络客户端（无第三方依赖、严格账号 Cookie 隔离、规避 CFBoolean JSON 陷阱）。
final class RainCheckClient: Sendable {
    static let defaultTimeoutInterval: TimeInterval = 25

    let session: URLSession
    let profile: ProtocolProfile

    init(session: URLSession = .shared, profile: ProtocolProfile = ProtocolCatalog.loadBundled()) {
        self.session = session
        self.profile = profile
    }

    static func isTimeoutError(_ error: Error) -> Bool {
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut
    }

    static func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    /// 校验账号会话并拉取用户基本信息（`me` 接口）。
    func fetchMe(account: Account) async throws -> VerifiedProfile {
        let result = await callEndpoint("me", account: account, variables: [:])
        if result.isCancelled || Task.isCancelled {
            throw CancellationError()
        }
        if result.httpStatus == -1 {
            throw RainCheckClientError.networkError(result.bodyText)
        }
        if !result.ok {
            let msg = result.message ?? "验证账号失败 (HTTP \(result.httpStatus))"
            if result.httpStatus == 401 || result.httpStatus == 403
                || matchesKeyword(msg, keywords: profile.result.authKeywords) {
                throw RainCheckClientError.authFailed(msg)
            }
            throw RainCheckClientError.invalidResponse(msg)
        }

        let name = result.firstNonBlankDataString("name", "userName", "nickname", "username")
        let userId = result.firstNonBlankDataString("id", "userId", "user_id")

        var refreshed = result.authUpdate?.apply(to: account, markOk: true) ?? account
        refreshed.lastOkAt = RainCheckTime.nowMillis()
        if let userId {
            refreshed.userId = userId
        }
        if let name, refreshed.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            refreshed.label = name
        }

        return VerifiedProfile(
            userId: userId,
            name: name,
            refreshedAccount: refreshed
        )
    }

    /// 调用协议配置文件中声明的具名接口。
    func callEndpoint(
        _ endpointKey: String,
        account: Account,
        variables: [String: TemplateValue] = [:],
        extraCookies: [String: String] = [:],
        timeoutInterval: TimeInterval? = nil
    ) async -> ApiCallResult {
        await executeEndpoint(
            endpointKey,
            account: account,
            variables: variables,
            extraCookies: extraCookies,
            referer: nil,
            extraHeaders: [:],
            timeoutInterval: timeoutInterval
        )
    }

    /// 内部扩展版本，支持附带 `Referer`、额外请求头与自定义超时时间。
    func executeEndpoint(
        _ endpointKey: String,
        account: Account,
        variables: [String: TemplateValue],
        extraCookies: [String: String],
        referer: String?,
        extraHeaders: [String: String],
        timeoutInterval: TimeInterval? = nil
    ) async -> ApiCallResult {
        guard let endpoint = profile.endpoint(endpointKey) else {
            return ApiCallResult(
                httpStatus: -1,
                bodyText: "profile 缺少 endpoint: \(endpointKey)",
                jsonObject: nil,
                businessCode: nil,
                message: "profile 缺少 endpoint: \(endpointKey)",
                elapsedMs: 0,
                authUpdate: nil,
                responseCookies: [:],
                ok: false,
                requestMethod: "GET",
                requestUrl: ""
            )
        }

        let base = "\(account.scheme)://\(account.host)"
        let renderedPath = TemplateRenderer.renderPath(endpoint.path, variables: variables)
        let renderedQuery = TemplateRenderer.renderQuery(endpoint.query, variables: variables)
        let urlString = TemplateRenderer.buildURL(base: base, path: renderedPath, query: renderedQuery)
        let renderedBody = endpoint.body.map { TemplateRenderer.renderBody($0, variables: variables) }

        return await performRequest(
            account: endpoint.auth ? account : nil,
            method: endpoint.method,
            urlString: urlString,
            body: renderedBody,
            extraCookies: extraCookies,
            referer: referer,
            extraHeaders: extraHeaders,
            timeoutInterval: timeoutInterval
        )
    }

    /// 直接发起带账号鉴权的 URL 请求（调用方须先行通过 `QrCodeParser.validateQrUrl` 安全校验）。
    func callDirectUrl(_ urlString: String, method: String, account: Account) async -> ApiCallResult {
        await performRequest(
            account: account,
            method: method,
            urlString: urlString,
            body: nil,
            extraCookies: [:],
            referer: nil,
            extraHeaders: [:],
            timeoutInterval: nil
        )
    }

    func callDirectUrl(
        _ urlString: String,
        method: String,
        account: Account,
        body: [String: TemplateValue]?,
        referer: String?
    ) async -> ApiCallResult {
        await performRequest(
            account: account,
            method: method,
            urlString: urlString,
            body: body,
            extraCookies: [:],
            referer: referer,
            extraHeaders: [:],
            timeoutInterval: nil
        )
    }

    // MARK: - JSON Parsing (CFBoolean Safe)

    /// 使用 `JSONSerialization` + `CFBooleanGetTypeID()` 显式区分布尔与数字，规避 `false == 0` 陷阱。
    static func parseJSONObject(from data: Data) -> [String: TemplateValue]? {
        guard !data.isEmpty,
              let raw = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let dict = raw as? [String: Any] else {
            return nil
        }
        var output: [String: TemplateValue] = [:]
        output.reserveCapacity(dict.count)
        for (key, value) in dict {
            output[key] = TemplateValue.fromFoundationObject(value)
        }
        return output
    }

    // MARK: - Core HTTP Pipeline

    private func performRequest(
        account: Account?,
        method: String,
        urlString: String,
        body: [String: TemplateValue]?,
        extraCookies: [String: String],
        referer: String?,
        extraHeaders: [String: String],
        timeoutInterval: TimeInterval? = nil
    ) async -> ApiCallResult {
        let normalizedMethod = method.uppercased()
        let startedMs = RainCheckTime.nowMillis()

        guard let url = URL(string: urlString) else {
            return ApiCallResult(
                httpStatus: -1,
                bodyText: "无效的请求地址: \(urlString)",
                jsonObject: nil,
                businessCode: nil,
                message: "无效的请求地址",
                elapsedMs: 0,
                authUpdate: nil,
                responseCookies: [:],
                ok: false,
                requestMethod: normalizedMethod,
                requestUrl: urlString
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = normalizedMethod
        let resolvedTimeout = timeoutInterval ?? Self.defaultTimeoutInterval
        request.timeoutInterval = resolvedTimeout > 0 ? resolvedTimeout : Self.defaultTimeoutInterval
        // 禁用系统共享 Cookie 池，彻底避免多账号并发串号或单测间污染
        request.httpShouldHandleCookies = false

        if !profile.userAgent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue(profile.userAgent, forHTTPHeaderField: "User-Agent")
        }

        for (headerKey, headerValue) in profile.headers {
            if body != nil && headerKey.caseInsensitiveCompare("Content-Type") == .orderedSame {
                continue
            }
            request.setValue(headerValue, forHTTPHeaderField: headerKey)
        }

        applyAuthAndCookies(to: &request, account: account, extraCookies: extraCookies)

        if let referer, !referer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }

        for (headerKey, headerValue) in extraHeaders {
            if body != nil && headerKey.caseInsensitiveCompare("Content-Type") == .orderedSame {
                continue
            }
            request.setValue(headerValue, forHTTPHeaderField: headerKey)
        }

        if let body {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let encoded = try? encoder.encode(body) {
                request.httpBody = encoded
                request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            }
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            let elapsed = max(0, RainCheckTime.nowMillis() - startedMs)
            let cancelled = Self.isCancellationError(error) || Task.isCancelled
            let timedOut = !cancelled && Self.isTimeoutError(error)
            return ApiCallResult(
                httpStatus: -1,
                bodyText: error.localizedDescription,
                jsonObject: nil,
                businessCode: nil,
                message: nil,
                elapsedMs: elapsed,
                authUpdate: nil,
                responseCookies: [:],
                ok: false,
                requestMethod: normalizedMethod,
                requestUrl: urlString,
                isTimeout: timedOut,
                isCancelled: cancelled
            )
        }

        let elapsed = max(0, RainCheckTime.nowMillis() - startedMs)
        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? -1
        let bodyText = String(data: data, encoding: .utf8) ?? ""
        let parsedJSON = Self.parseJSONObject(from: data)

        let businessCode: Int? = parsedJSON.flatMap { obj in
            for key in profile.result.allCodeKeys() {
                if let val = obj[key]?.intValue {
                    return val
                }
            }
            return nil
        }

        let message: String? = parsedJSON.flatMap { obj in
            for key in profile.result.allMessageKeys() {
                if let str = obj[key]?.stringValue,
                   !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return str
                }
            }
            return nil
        }

        let extracted: (auth: AuthUpdate?, cookies: [String: String])
        if (200...399).contains(httpStatus), let httpResponse = response as? HTTPURLResponse {
            extracted = extractAuthAndCookies(
                from: httpResponse,
                responseURL: httpResponse.url ?? url,
                account: account
            )
        } else {
            extracted = (nil, [:])
        }

        let isOk = (200...299).contains(httpStatus) && profile.result.isOkCode(businessCode)

        return ApiCallResult(
            httpStatus: httpStatus,
            bodyText: bodyText,
            jsonObject: parsedJSON,
            businessCode: businessCode,
            message: message,
            elapsedMs: elapsed,
            authUpdate: extracted.auth,
            responseCookies: extracted.cookies,
            ok: isOk,
            requestMethod: normalizedMethod,
            requestUrl: urlString
        )
    }

    private func applyAuthAndCookies(
        to request: inout URLRequest,
        account: Account?,
        extraCookies: [String: String]
    ) {
        let sessionCookieName = profile.auth.primarySessionCookie()
        let csrfCookieName = profile.auth.effectiveCsrfCookie()

        var cookiePairs: [(name: String, value: String)] = []
        var cookieIndexByLowerName: [String: Int] = [:]

        func setCookie(name: String, value: String) {
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty, !trimmedValue.isEmpty else { return }
            let lower = trimmedName.lowercased()
            if let existingIdx = cookieIndexByLowerName[lower] {
                cookiePairs[existingIdx] = (trimmedName, trimmedValue)
            } else {
                cookieIndexByLowerName[lower] = cookiePairs.count
                cookiePairs.append((trimmedName, trimmedValue))
            }
        }

        for key in extraCookies.keys.sorted() {
            if let value = extraCookies[key] {
                setCookie(name: key, value: value)
            }
        }

        var effectiveCsrf: String? = extraCookies.first {
            $0.key.caseInsensitiveCompare(csrfCookieName) == .orderedSame
        }?.value

        if let account {
            if let rawBearer = account.bearer,
               !rawBearer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let bare = stripBearerPrefix(rawBearer)
                if !bare.isEmpty {
                    request.setValue(
                        profile.auth.bearerPrefix + bare,
                        forHTTPHeaderField: profile.auth.bearerHeader
                    )
                }
            }
            if let sid = account.sessionId,
               !sid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                setCookie(name: sessionCookieName, value: sid)
            }
            if let csrf = account.csrfToken,
               !csrf.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                setCookie(name: csrfCookieName, value: csrf)
                effectiveCsrf = csrf
            }
        }

        if !cookiePairs.isEmpty {
            let header = cookiePairs.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            request.setValue(header, forHTTPHeaderField: "Cookie")
        }

        if let effectiveCsrf, !effectiveCsrf.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue(effectiveCsrf, forHTTPHeaderField: profile.auth.csrfHeader)
        }
    }

    private func extractAuthAndCookies(
        from response: HTTPURLResponse,
        responseURL: URL,
        account: Account?
    ) -> (auth: AuthUpdate?, cookies: [String: String]) {
        var stringHeaders: [String: String] = [:]
        var lowerToValue: [String: String] = [:]

        for (rawKey, rawValue) in response.allHeaderFields {
            guard let key = rawKey as? String else { continue }
            let value = String(describing: rawValue)
            let normalizedKey = key.caseInsensitiveCompare("set-cookie") == .orderedSame ? "Set-Cookie" : key
            stringHeaders[normalizedKey] = value
            lowerToValue[key.lowercased()] = value
        }

        // 按配置顺序提取 Bearer（确保 set-auth 优先于 authorization）
        var extractedBearer: String?
        for headerName in profile.auth.tokenResponseHeaders {
            if let rawToken = lowerToValue[headerName.lowercased()],
               !rawToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let bare = stripBearerPrefix(rawToken)
                if !bare.isEmpty {
                    extractedBearer = bare
                    break
                }
            }
        }

        let csrfCookieName = profile.auth.effectiveCsrfCookie()
        let acceptedSessionNames = profile.auth.acceptedSessionCookies()

        var responseCookies: [String: String] = [:]
        var extractedSessionId: String?
        var extractedCsrf: String?

        let parsedCookies = HTTPCookie.cookies(withResponseHeaderFields: stringHeaders, for: responseURL)
        let now = Date()
        for cookie in parsedCookies {
            if let maxAgeRaw = cookie.properties?[.maximumAge] as? String,
               let maxAge = Int(maxAgeRaw),
               maxAge <= 0 {
                continue
            }
            if let expires = cookie.expiresDate, expires <= now {
                continue
            }
            let cleanedValue = cookie.value
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"")))
            if cleanedValue.isEmpty || cleanedValue.caseInsensitiveCompare("deleted") == .orderedSame {
                continue
            }

            responseCookies[cookie.name] = cleanedValue

            if cookie.name.caseInsensitiveCompare(csrfCookieName) == .orderedSame {
                extractedCsrf = cleanedValue
            } else if acceptedSessionNames.contains(where: { $0.caseInsensitiveCompare(cookie.name) == .orderedSame }) {
                extractedSessionId = cleanedValue
            }
        }

        let effectiveBearer: String?
        let effectiveSession: String?
        let effectiveCsrf: String?

        if let account {
            effectiveBearer = (extractedBearer != nil && extractedBearer != account.bearer) ? extractedBearer : nil
            effectiveSession = (extractedSessionId != nil && extractedSessionId != account.sessionId) ? extractedSessionId : nil
            effectiveCsrf = (extractedCsrf != nil && extractedCsrf != account.csrfToken) ? extractedCsrf : nil
        } else {
            effectiveBearer = extractedBearer
            effectiveSession = extractedSessionId
            effectiveCsrf = extractedCsrf
        }

        let authUpdate: AuthUpdate?
        if effectiveBearer != nil || effectiveSession != nil || effectiveCsrf != nil {
            authUpdate = AuthUpdate(
                bearer: effectiveBearer,
                sessionId: effectiveSession,
                csrfToken: effectiveCsrf
            )
        } else {
            authUpdate = nil
        }

        return (authUpdate, responseCookies)
    }

    private func stripBearerPrefix(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = profile.auth.bearerPrefix
        if !prefix.isEmpty && trimmed.lowercased().hasPrefix(prefix.lowercased()) {
            return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let trimmedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPrefix.isEmpty && trimmed.lowercased().hasPrefix("\(trimmedPrefix.lowercased()) ") {
            return String(trimmed.dropFirst(trimmedPrefix.count + 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private func matchesKeyword(_ text: String, keywords: [String]) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()
        return keywords.contains { keyword in
            let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            return !kw.isEmpty && lower.contains(kw.lowercased())
        }
    }
}
