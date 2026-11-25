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
    let finalUrl: String?
    let rawSnippet: String?
    let isHtmlBody: Bool
    let jsonSuccess: Bool?
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
        finalUrl: String? = nil,
        rawSnippet: String? = nil,
        isHtmlBody: Bool = false,
        jsonSuccess: Bool? = nil,
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
        self.finalUrl = finalUrl
        self.rawSnippet = rawSnippet
        self.isHtmlBody = isHtmlBody
        self.jsonSuccess = jsonSuccess
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

    /// 面向诊断展示的可读摘要（绝不输出空白字符串或原始 HTML 源码）。
    var diagnosticSummary: String {
        if httpStatus == -1 {
            let trimmed = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "网络连接异常" : (CredentialSanitizer.sanitizeDiagnosticSnippet(trimmed, maxLength: 160) ?? "网络连接异常")
        }
        if let msg = message?.trimmingCharacters(in: .whitespacesAndNewlines), !msg.isEmpty {
            return msg
        }
        if isHtmlBody {
            if let title = RainCheckClient.extractHTMLTitle(from: bodyText) {
                return "服务器返回 HTML 页面：\(title)（HTTP \(httpStatus)）"
            }
            return "服务器返回 HTML 页面（HTTP \(httpStatus)）"
        }
        if let snippet = rawSnippet?.trimmingCharacters(in: .whitespacesAndNewlines), !snippet.isEmpty {
            return snippet
        }
        let trimmedBody = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedBody.isEmpty {
            return CredentialSanitizer.sanitizeDiagnosticSnippet(trimmedBody, maxLength: 160) ?? "HTTP \(httpStatus)"
        }
        return "HTTP \(httpStatus)（空响应）"
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
    /// 当账号同时持有短期 `bearer`（如课堂 `set-auth`）与长期 `sessionId` 且首次鉴权失败时，
    /// 自动回退为纯 Cookie 重试一次；若回退成功则清空已过期的旧 `bearer`。
    func fetchMe(account: Account) async throws -> VerifiedProfile {
        let initialResult = await callEndpoint("me", account: account, variables: [:])
        if initialResult.isCancelled || Task.isCancelled {
            throw CancellationError()
        }

        let hasBearer = !(account.bearer?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasSession = !(account.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

        var activeAccount = account
        var finalResult = initialResult

        if !initialResult.ok && hasBearer && hasSession && isAuthFailure(initialResult) {
            var cookieOnlyAccount = account
            cookieOnlyAccount.bearer = nil
            let retryResult = await callEndpoint("me", account: cookieOnlyAccount, variables: [:])
            if retryResult.isCancelled || Task.isCancelled {
                throw CancellationError()
            }
            if retryResult.ok {
                activeAccount = cookieOnlyAccount
            }
            finalResult = retryResult
        }

        if finalResult.httpStatus == -1 {
            throw RainCheckClientError.networkError(finalResult.bodyText)
        }
        if !finalResult.ok {
            let msg = finalResult.message ?? "验证账号失败（\(finalResult.diagnosticSummary)）"
            if isAuthFailure(finalResult) {
                throw RainCheckClientError.authFailed(msg)
            }
            throw RainCheckClientError.invalidResponse(msg)
        }

        let name = finalResult.firstNonBlankDataString("name", "userName", "nickname", "username")
        let userId = finalResult.firstNonBlankDataString("id", "userId", "user_id")

        var refreshed = finalResult.authUpdate?.apply(to: activeAccount, markOk: true) ?? activeAccount
        refreshed.lastOkAt = RainCheckTime.nowMillis()
        if let userId {
            refreshed.userId = userId
        }
        if let name, Account.isPlaceholderLabel(refreshed.label) {
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

        var mergedHeaders = endpoint.headers
        for (extraKey, extraVal) in extraHeaders {
            // 大小写不敏感去重覆盖 endpoint.headers
            for existingKey in Array(mergedHeaders.keys) where existingKey.caseInsensitiveCompare(extraKey) == .orderedSame {
                mergedHeaders.removeValue(forKey: existingKey)
            }
            mergedHeaders[extraKey] = extraVal
        }

        return await performRequest(
            account: endpoint.auth ? account : nil,
            method: endpoint.method,
            urlString: urlString,
            body: renderedBody,
            extraCookies: extraCookies,
            referer: referer,
            extraHeaders: mergedHeaders,
            alignRefererToTargetOrigin: false,
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
            alignRefererToTargetOrigin: true,
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
            alignRefererToTargetOrigin: true,
            timeoutInterval: nil
        )
    }

    // MARK: - JSON Parsing & HTML Diagnostics (CFBoolean Safe)

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

    static func looksLikeHTML(_ text: String, contentType: String? = nil) -> Bool {
        if let ct = contentType?.lowercased(),
           ct.contains("text/html") || ct.contains("application/xhtml") {
            return true
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lowerPrefix = String(trimmed.prefix(256)).lowercased()
        return lowerPrefix.hasPrefix("<!doctype html")
            || lowerPrefix.hasPrefix("<html")
            || lowerPrefix.hasPrefix("<head")
            || lowerPrefix.hasPrefix("<body")
            || lowerPrefix.contains("<html")
            || lowerPrefix.contains("<!doctype html")
    }

    static func extractHTMLTitle(from html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"(?is)<title\b[^>]*>(.*?)</title>"#, options: []) else {
            return nil
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: range),
              match.numberOfRanges > 1,
              let titleRange = Range(match.range(at: 1), in: html) else {
            return nil
        }
        let rawTitle = String(html[titleRange])
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        return CredentialSanitizer.sanitizeDiagnosticSnippet(rawTitle, maxLength: 80)
    }

    private static func strictNonBlankString(_ value: TemplateValue?) -> String? {
        guard case .string(let str) = value else { return nil }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func extractBusinessCode(from parsedJSON: [String: TemplateValue]) -> Int? {
        var keys = profile.result.allCodeKeys()
        for fallbackKey in ["error_code", "status_code", "statusCode", "errno"] where !keys.contains(fallbackKey) {
            keys.append(fallbackKey)
        }
        for key in keys {
            if let val = parsedJSON[key]?.intValue {
                return val
            }
        }
        return nil
    }

    private func extractMessage(from parsedJSON: [String: TemplateValue]) -> String? {
        var keys = profile.result.allMessageKeys()
        for fallbackKey in ["errormsg", "detail", "error", "err", "info", "reason", "status_msg", "statusMsg"]
            where !keys.contains(fallbackKey) {
            keys.append(fallbackKey)
        }
        for key in keys {
            if let str = Self.strictNonBlankString(parsedJSON[key]) {
                return str
            }
        }
        if let nestedData = parsedJSON["data"]?.objectValue {
            for key in ["msg", "message", "errmsg", "errormsg", "detail", "error", "reason"] {
                if let str = Self.strictNonBlankString(nestedData[key]) {
                    return str
                }
            }
        }
        if let directDataString = Self.strictNonBlankString(parsedJSON["data"]) {
            return directDataString
        }
        return nil
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
        alignRefererToTargetOrigin: Bool = false,
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
        // 禁止本地/远端 URLCache 返回陈旧响应（避免进行中课堂列表或动态码接口读到缓存）
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let resolvedTimeout = timeoutInterval ?? Self.defaultTimeoutInterval
        request.timeoutInterval = resolvedTimeout > 0 ? resolvedTimeout : Self.defaultTimeoutInterval
        // 禁用系统共享 Cookie 池，彻底避免多账号并发串号或单测间污染
        request.httpShouldHandleCookies = false

        let origin = Self.sameOrigin(for: url)
        let normalizedHost = url.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let isXuetangX = normalizedHost == "xuetangx.com" || normalizedHost.hasSuffix(".xuetangx.com")
        let defaultXtbz = isXuetangX ? "xt" : "ykt"

        if !profile.userAgent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue(profile.userAgent, forHTTPHeaderField: "User-Agent")
        }

        // 默认采用官方 Web 端请求头，避免历史 desktop-v / X-Client: desktop / Origin: file:// 导致 Web sessionid 401
        request.setValue(defaultXtbz, forHTTPHeaderField: "xtbz")
        request.setValue("web", forHTTPHeaderField: "X-Client")
        if let origin {
            request.setValue(origin, forHTTPHeaderField: "Origin")
            request.setValue("\(origin)/v2/web/index", forHTTPHeaderField: "Referer")
        }

        for (headerKey, headerValue) in profile.headers {
            if body != nil && headerKey.caseInsensitiveCompare("Content-Type") == .orderedSame {
                continue
            }
            if headerKey.caseInsensitiveCompare("desktop-v") == .orderedSame {
                continue
            }
            let trimmedValue = headerValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if headerKey.caseInsensitiveCompare("X-Client") == .orderedSame {
                let normalizedClient = (trimmedValue.isEmpty || trimmedValue.caseInsensitiveCompare("desktop") == .orderedSame)
                    ? "web"
                    : trimmedValue
                request.setValue(normalizedClient, forHTTPHeaderField: "X-Client")
                continue
            }
            if headerKey.caseInsensitiveCompare("Origin") == .orderedSame {
                if trimmedValue.isEmpty || trimmedValue.lowercased().hasPrefix("file://") {
                    if let origin {
                        request.setValue(origin, forHTTPHeaderField: "Origin")
                    }
                } else {
                    request.setValue(trimmedValue, forHTTPHeaderField: "Origin")
                }
                continue
            }
            if headerKey.caseInsensitiveCompare("Referer") == .orderedSame {
                if !trimmedValue.isEmpty {
                    request.setValue(trimmedValue, forHTTPHeaderField: "Referer")
                }
                continue
            }
            if headerKey.caseInsensitiveCompare("xtbz") == .orderedSame {
                let normalizedXtbz = isXuetangX ? "xt" : (trimmedValue.isEmpty ? "ykt" : trimmedValue)
                request.setValue(normalizedXtbz, forHTTPHeaderField: "xtbz")
                continue
            }
            request.setValue(headerValue, forHTTPHeaderField: headerKey)
        }

        applyAuthAndCookies(to: &request, account: account, extraCookies: extraCookies)

        // 若为直接二维码 URL 请求（QR_URL_POST / QR_URL_GET），确保 Origin 与 Referer 严格来自目标 URL 同源，绝不混用 account.host Referer
        if let referer, !referer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if alignRefererToTargetOrigin,
               let targetOrigin = origin,
               let refUrl = URL(string: referer),
               let refOrigin = Self.sameOrigin(for: refUrl),
               refOrigin.caseInsensitiveCompare(targetOrigin) != .orderedSame {
                request.setValue("\(targetOrigin)/v2/web/index", forHTTPHeaderField: "Referer")
            } else {
                request.setValue(referer, forHTTPHeaderField: "Referer")
            }
        } else if alignRefererToTargetOrigin, let targetOrigin = origin {
            request.setValue("\(targetOrigin)/v2/web/index", forHTTPHeaderField: "Referer")
        }

        var isAppClientOverride = false
        for (headerKey, headerValue) in extraHeaders {
            if body != nil && headerKey.caseInsensitiveCompare("Content-Type") == .orderedSame {
                continue
            }
            if headerKey.caseInsensitiveCompare("desktop-v") == .orderedSame {
                continue
            }
            let trimmedValue = headerValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if headerKey.caseInsensitiveCompare("X-Client") == .orderedSame {
                if !trimmedValue.isEmpty {
                    if trimmedValue.caseInsensitiveCompare("app") == .orderedSame {
                        isAppClientOverride = true
                    }
                    // 尊重接口级 x-client 声明（例如官方 App 扫码的 x-client: app），先清旧键防止大小写冲突
                    request.setValue(nil, forHTTPHeaderField: "X-Client")
                    request.setValue(trimmedValue, forHTTPHeaderField: headerKey)
                }
                continue
            }
            if headerKey.caseInsensitiveCompare("Origin") == .orderedSame,
               trimmedValue.lowercased().hasPrefix("file://") {
                if let origin {
                    request.setValue(origin, forHTTPHeaderField: "Origin")
                }
                continue
            }
            request.setValue(headerValue, forHTTPHeaderField: headerKey)
        }

        if isAppClientOverride,
           let uid = account?.userId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !uid.isEmpty {
            request.setValue(uid, forHTTPHeaderField: "X-UID")
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
                finalUrl: nil,
                rawSnippet: CredentialSanitizer.sanitizeDiagnosticSnippet(error.localizedDescription, maxLength: 200),
                isHtmlBody: false,
                jsonSuccess: nil,
                isTimeout: timedOut,
                isCancelled: cancelled
            )
        }

        let elapsed = max(0, RainCheckTime.nowMillis() - startedMs)
        let httpResponse = response as? HTTPURLResponse
        let httpStatus = httpResponse?.statusCode ?? -1
        let finalUrl = httpResponse?.url?.absoluteString
        let contentType = httpResponse?.value(forHTTPHeaderField: "Content-Type")

        let bodyText: String
        if data.isEmpty {
            bodyText = ""
        } else if let utf8 = String(data: data, encoding: .utf8) {
            bodyText = utf8
        } else if let latin1 = String(data: data, encoding: .isoLatin1) {
            bodyText = latin1
        } else {
            bodyText = "<binary \(data.count) bytes>"
        }

        let parsedJSON = Self.parseJSONObject(from: data)
        let isHtml = (parsedJSON == nil) && Self.looksLikeHTML(bodyText, contentType: contentType)

        let businessCode = parsedJSON.flatMap { extractBusinessCode(from: $0) }
        let message = parsedJSON.flatMap { extractMessage(from: $0) }
        let jsonSuccess = parsedJSON?["success"]?.boolValue

        let rawSnippet: String?
        if isHtml {
            if let title = Self.extractHTMLTitle(from: bodyText) {
                rawSnippet = CredentialSanitizer.sanitizeDiagnosticSnippet("HTML <title>: \(title)", maxLength: 200)
            } else {
                rawSnippet = CredentialSanitizer.sanitizeDiagnosticSnippet(bodyText, maxLength: 200)
            }
        } else {
            rawSnippet = CredentialSanitizer.sanitizeDiagnosticSnippet(bodyText, maxLength: 200)
        }

        let extracted: (auth: AuthUpdate?, cookies: [String: String])
        if let httpResponse, ((200...399).contains(httpStatus) || httpStatus == 403) {
            extracted = extractAuthAndCookies(
                from: httpResponse,
                responseURL: httpResponse.url ?? url,
                account: account
            )
        } else {
            extracted = (nil, [:])
        }

        let hasExplicitOkCode = profile.result.isOkCode(businessCode)
        let isSuccessFlagOk = (jsonSuccess == true) && (businessCode == nil || hasExplicitOkCode)
        let isOk = (200...299).contains(httpStatus) && (hasExplicitOkCode || isSuccessFlagOk)

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
            requestUrl: urlString,
            finalUrl: finalUrl,
            rawSnippet: rawSnippet,
            isHtmlBody: isHtml,
            jsonSuccess: jsonSuccess
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
        var rejectedCookieNames: Set<String> = []

        let parsedCookies = HTTPCookie.cookies(withResponseHeaderFields: stringHeaders, for: responseURL)
        let now = Date()
        for cookie in parsedCookies {
            if let maxAgeRaw = cookie.properties?[.maximumAge] as? String,
               let maxAge = Int(maxAgeRaw),
               maxAge <= 0 {
                rejectedCookieNames.insert(cookie.name.lowercased())
                continue
            }
            if let expires = cookie.expiresDate, expires <= now {
                rejectedCookieNames.insert(cookie.name.lowercased())
                continue
            }
            let cleanedValue = cookie.value
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"")))
            if cleanedValue.isEmpty || cleanedValue.caseInsensitiveCompare("deleted") == .orderedSame {
                rejectedCookieNames.insert(cookie.name.lowercased())
                continue
            }

            rejectedCookieNames.remove(cookie.name.lowercased())
            responseCookies[cookie.name] = cleanedValue

            if cookie.name.caseInsensitiveCompare(csrfCookieName) == .orderedSame {
                extractedCsrf = cleanedValue
            } else if acceptedSessionNames.contains(where: { $0.caseInsensitiveCompare(cookie.name) == .orderedSame }) {
                extractedSessionId = cleanedValue
            }
        }

        // 兜底兼容逗号或分号拼接多条 Cookie 的 Set-Cookie 响应头（绝不误切 expires 日期中的逗号）
        if let rawSetCookie = stringHeaders["Set-Cookie"] {
            if extractedSessionId == nil {
                for candidate in acceptedSessionNames where !rejectedCookieNames.contains(candidate.lowercased()) {
                    if let cleaned = CredentialSanitizer.cleanCookieValue(rawSetCookie, key: candidate, allowBareValue: false) {
                        extractedSessionId = cleaned
                        responseCookies[candidate] = cleaned
                        break
                    }
                }
            }
            if extractedCsrf == nil,
               !rejectedCookieNames.contains(csrfCookieName.lowercased()),
               let cleaned = CredentialSanitizer.cleanCookieValue(rawSetCookie, key: csrfCookieName, allowBareValue: false) {
                extractedCsrf = cleaned
                responseCookies[csrfCookieName] = cleaned
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

    private static func sameOrigin(for url: URL) -> String? {
        guard let scheme = url.scheme?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !scheme.isEmpty,
              let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !host.isEmpty else {
            return nil
        }
        let formattedHost = (host.contains(":") && !host.hasPrefix("[")) ? "[\(host)]" : host
        if let port = url.port {
            let isDefaultPort = (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
            if !isDefaultPort {
                return "\(scheme)://\(formattedHost):\(port)"
            }
        }
        return "\(scheme)://\(formattedHost)"
    }

    private func isAuthFailure(_ result: ApiCallResult) -> Bool {
        if result.httpStatus == 401 || result.httpStatus == 403 {
            return true
        }
        if result.businessCode == 401 {
            return true
        }
        if result.businessCode == 50000 && !(500...599).contains(result.httpStatus) {
            return true
        }
        let trimmedMessage = result.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text: String
        if !trimmedMessage.isEmpty {
            text = trimmedMessage
        } else if result.isHtmlBody {
            text = Self.extractHTMLTitle(from: result.bodyText) ?? ""
        } else {
            text = result.bodyText
        }
        if matchesKeyword(text, keywords: profile.result.authKeywords) {
            return true
        }
        return false
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
