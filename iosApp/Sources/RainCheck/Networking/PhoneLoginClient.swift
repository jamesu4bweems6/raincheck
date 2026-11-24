import Foundation

/// 人机安全验证凭据（腾讯防水墙 `ticket` / `randstr` 或降级 `hcaptcha_token`）。
struct CaptchaToken: Sendable, Equatable, Hashable {
    let ticket: String
    let randstr: String
    let hcaptchaToken: String

    init(ticket: String = "", randstr: String = "", hcaptchaToken: String = "") {
        self.ticket = ticket
        self.randstr = randstr
        self.hcaptchaToken = hcaptchaToken
    }
}

/// 手机号短信验证码登录错误类型。
enum PhoneLoginError: Error, LocalizedError, Equatable, Sendable {
    case invalidPhone
    case invalidCode
    case unsupportedEdition(String)
    case captchaRequired(String)
    case serverError(code: Int?, message: String)
    case networkError(String)
    case missingCredentials

    var errorDescription: String? {
        switch self {
        case .invalidPhone:
            return "请输入正确的 11 位中国大陆手机号"
        case .invalidCode:
            return "请输入有效的数字短信验证码（4–8 位）"
        case .unsupportedEdition(let message):
            return message
        case .captchaRequired(let message):
            return message
        case .serverError(_, let message):
            return message
        case .networkError(let message):
            return message
        case .missingCredentials:
            return "登录成功但服务端未返回有效会话凭据（sessionid / set-auth）"
        }
    }
}

/// 雨课堂官方 Web `/pc/login/*` 手机号 + 短信验证码登录客户端。
final class PhoneLoginClient: Sendable {
    static let tencentCaptchaAppId = "2091064951"
    static let hcaptchaSiteKey = "50f6f060-c606-4e3b-b6e8-ca3b706b61e1"

    let session: URLSession
    let profile: ProtocolProfile
    let client: RainCheckClient

    init(session: URLSession = .shared, profile: ProtocolProfile = ProtocolCatalog.loadBundled()) {
        self.session = session
        self.profile = profile
        self.client = RainCheckClient(session: session, profile: profile)
    }

    /// 清理空格与连字符后校验中国大陆 11 位手机号（`^1[3456789]\d{9}$`）。
    static func isValidMainlandPhone(_ raw: String) -> Bool {
        let cleaned = cleanPhone(raw)
        let chars = Array(cleaned)
        guard chars.count == 11 else { return false }
        guard chars[0] == "1" else { return false }
        guard "3456789".contains(chars[1]) else { return false }
        return chars.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// 远端 HTTPS 站点发送短信前需通过腾讯防水墙人机验证；本地 `mock` / `127.0.0.1` / `localhost` 直接放行。
    static func requiresWebCaptcha(for edition: Edition) -> Bool {
        let scheme = edition.scheme.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard scheme == "https" else {
            return false
        }
        if edition.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "mock" {
            return false
        }
        let rawHost = edition.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parsedHost = URLComponents(string: "\(scheme)://\(rawHost)")?.host?.lowercased() ?? rawHost
        if parsedHost.isEmpty
            || parsedHost == "127.0.0.1"
            || parsedHost == "localhost"
            || parsedHost == "::1"
            || parsedHost.hasSuffix(".local") {
            return false
        }
        return true
    }

    /// 1. 请求下发登录短信验证码（`POST /pc/login/send_sms_login_code/`，保留末尾斜杠）。
    func sendSmsCode(edition: Edition, phone: String, captcha: CaptchaToken) async throws {
        if Self.isUnsupportedEdition(edition) {
            throw PhoneLoginError.unsupportedEdition("学堂在线暂不支持手机号验证码登录，请切换雨课堂各站点或手动导入")
        }

        let cleanedPhone = Self.cleanPhone(phone)
        guard Self.isValidMainlandPhone(cleanedPhone) else {
            throw PhoneLoginError.invalidPhone
        }

        let payload = SendSmsPayload(
            mobile: cleanedPhone,
            login: true,
            ticket: captcha.ticket.trimmingCharacters(in: .whitespacesAndNewlines),
            randstr: captcha.randstr.trimmingCharacters(in: .whitespacesAndNewlines),
            hcaptchaToken: captcha.hcaptchaToken.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        let request = try buildRequest(
            edition: edition,
            path: "/pc/login/send_sms_login_code/",
            payload: payload
        )

        let (data, httpResponse) = try await perform(request)
        let parsed = Self.parsePcLoginResponse(from: data)

        guard (200...299).contains(httpResponse.statusCode), parsed?.success == true else {
            throw Self.mapFailureError(
                httpStatus: httpResponse.statusCode,
                response: parsed,
                defaultMessage: "发送短信验证码失败 (HTTP \(httpResponse.statusCode))"
            )
        }
    }

    /// 2. 使用手机号 + 短信验证码登录（`POST /pc/login/verify_pwd_login/`，保留末尾斜杠），
    /// 提取 `Set-Cookie`（`sessionid` / `csrftoken`）与可选 `set-auth`，并尝试拉取 `basic-info` 丰富用户信息。
    func loginWithSmsCode(edition: Edition, phone: String, code: String) async throws -> Account {
        if Self.isUnsupportedEdition(edition) {
            throw PhoneLoginError.unsupportedEdition("学堂在线暂不支持手机号验证码登录，请切换雨课堂各站点或手动导入")
        }

        let cleanedPhone = Self.cleanPhone(phone)
        guard Self.isValidMainlandPhone(cleanedPhone) else {
            throw PhoneLoginError.invalidPhone
        }

        let cleanedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (4...8).contains(cleanedCode.count),
              cleanedCode.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw PhoneLoginError.invalidCode
        }

        let payload = VerifyPwdLoginPayload(
            type: "PC",
            name: cleanedPhone,
            pwd: cleanedCode
        )

        let request = try buildRequest(
            edition: edition,
            path: "/pc/login/verify_pwd_login/",
            payload: payload
        )

        let (data, httpResponse) = try await perform(request)
        let parsed = Self.parsePcLoginResponse(from: data)

        guard (200...299).contains(httpResponse.statusCode), parsed?.success == true else {
            throw Self.mapFailureError(
                httpStatus: httpResponse.statusCode,
                response: parsed,
                defaultMessage: "手机号登录失败 (HTTP \(httpResponse.statusCode))"
            )
        }

        guard let responseURL = httpResponse.url ?? request.url else {
            throw PhoneLoginError.networkError("缺少有效的响应地址")
        }
        let credentials = extractCredentials(from: httpResponse, responseURL: responseURL)
        guard credentials.bearer != nil || credentials.sessionId != nil else {
            throw PhoneLoginError.missingCredentials
        }

        let suffix4 = String(cleanedPhone.suffix(4))
        let fallbackLabel = "雨课堂用户(\(suffix4))"
        let candidate = Account(
            id: UUID().uuidString,
            label: fallbackLabel,
            host: edition.host,
            scheme: edition.scheme,
            bearer: credentials.bearer,
            sessionId: credentials.sessionId,
            csrfToken: credentials.csrfToken,
            enabled: true,
            createdAt: RainCheckTime.nowMillis(),
            lastOkAt: nil,
            userId: nil,
            note: ""
        )

        do {
            let verified = try await client.fetchMe(account: candidate)
            var enriched = verified.refreshedAccount ?? candidate
            if let name = Self.nonEmpty(verified.name) {
                enriched.label = name
            }
            if let uid = Self.nonEmpty(verified.userId) {
                enriched.userId = uid
            }
            enriched.lastOkAt = RainCheckTime.nowMillis()
            return enriched
        } catch {
            if RainCheckClient.isCancellationError(error) || Task.isCancelled {
                throw CancellationError()
            }
            // basic-info 临时降级时仍保留有效会话凭据与脱敏后四位标签
            return candidate
        }
    }

    // MARK: - Private Types

    private struct SendSmsPayload: Encodable, Sendable {
        let mobile: String
        let login: Bool
        let ticket: String
        let randstr: String
        let hcaptchaToken: String

        enum CodingKeys: String, CodingKey {
            case mobile
            case login
            case ticket
            case randstr
            case hcaptchaToken = "hcaptcha_token"
        }
    }

    private struct VerifyPwdLoginPayload: Encodable, Sendable {
        let type: String
        let name: String
        let pwd: String
    }

    private struct PcLoginResponse: Sendable {
        let success: Bool?
        let statusCode: Int?
        let message: String?
    }

    private struct ExtractedCredentials: Sendable {
        let bearer: String?
        let sessionId: String?
        let csrfToken: String?
    }

    // MARK: - Request & Response Helpers

    private static func cleanPhone(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
    }

    private static func isUnsupportedEdition(_ edition: Edition) -> Bool {
        edition.host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .contains("xuetangx.com")
    }

    private func buildRequest<Payload: Encodable>(
        edition: Edition,
        path: String,
        payload: Payload
    ) throws -> URLRequest {
        let scheme = edition.scheme.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let host = edition.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = "\(scheme)://\(host)"
        let urlString = "\(origin)\(path)"

        guard let url = URL(string: urlString) else {
            throw PhoneLoginError.networkError("无效的请求地址: \(urlString)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = RainCheckClient.defaultTimeoutInterval
        // 禁用系统共享 Cookie 池，避免多账号并发串号或单测污染
        request.httpShouldHandleCookies = false

        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue("\(origin)/web", forHTTPHeaderField: "Referer")

        let userAgent = profile.userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !userAgent.isEmpty {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            request.httpBody = try encoder.encode(payload)
        } catch {
            throw PhoneLoginError.networkError("构造登录请求失败: \(error.localizedDescription)")
        }

        return request
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if RainCheckClient.isCancellationError(error) || Task.isCancelled {
                throw CancellationError()
            }
            if RainCheckClient.isTimeoutError(error) {
                throw PhoneLoginError.networkError("网络请求超时，请检查网络后重试")
            }
            throw PhoneLoginError.networkError("网络请求异常：\(error.localizedDescription)")
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PhoneLoginError.networkError("服务端未返回有效的 HTTP 响应")
        }
        return (data, httpResponse)
    }

    /// 使用 `JSONSerialization` + `CFBooleanGetTypeID()` 严格区分布尔 `success` 与数值 `status_code`。
    private static func parsePcLoginResponse(from data: Data) -> PcLoginResponse? {
        guard !data.isEmpty,
              let raw = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let dict = raw as? [String: Any] else {
            return nil
        }

        let success: Bool? = {
            guard let rawSuccess = dict["success"], !(rawSuccess is NSNull) else {
                return nil
            }
            if let number = rawSuccess as? NSNumber,
               CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() {
                return number.boolValue
            }
            return nil
        }()

        let statusCode: Int? = {
            for key in ["status_code", "statusCode", "code"] {
                guard let rawValue = dict[key], !(rawValue is NSNull) else { continue }
                if let number = rawValue as? NSNumber {
                    if CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() {
                        continue
                    }
                    return number.intValue
                }
                if let text = rawValue as? String,
                   let parsed = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    return parsed
                }
            }
            return nil
        }()

        let message: String? = {
            for key in ["msg", "message", "detail"] {
                if let text = dict[key] as? String, let cleaned = nonEmpty(text) {
                    return cleaned
                }
            }
            return nil
        }()

        return PcLoginResponse(success: success, statusCode: statusCode, message: message)
    }

    private static func mapFailureError(
        httpStatus: Int,
        response: PcLoginResponse?,
        defaultMessage: String
    ) -> PhoneLoginError {
        let code = response?.statusCode
        let serverMessage = response?.message

        switch code {
        case 300402:
            return .serverError(code: 300402, message: "无效的手机号格式")
        case 300404:
            return .serverError(code: 300404, message: "验证码已过期或已被使用，请重新获取")
        case 300405:
            return .serverError(code: 300405, message: "验证码错误，请核对后重试")
        case 300408:
            return .captchaRequired("发送短信验证码失败，请完成安全验证后重试")
        case 300409:
            return .serverError(code: 300409, message: "该手机号账号不存在或未绑定")
        case 300411:
            return .serverError(code: 300411, message: "错误的登录类型")
        case 300412:
            return .serverError(code: 300412, message: "校验失败或账号错误")
        case 300415:
            return .serverError(code: 300415, message: "验证码已发送，请稍后再试")
        case 300416:
            return .captchaRequired("腾讯防水墙校验失败，请重新验证")
        case 300417:
            return .serverError(code: 300417, message: "登录成功但尚未完成高校身份绑定，请先前往雨课堂网页端完成绑定")
        default:
            let message = serverMessage ?? defaultMessage
            return .serverError(code: code, message: message)
        }
    }

    private func extractCredentials(
        from response: HTTPURLResponse,
        responseURL: URL
    ) -> ExtractedCredentials {
        var stringHeaders: [String: String] = [:]
        var lowerToValue: [String: String] = [:]

        for (rawKey, rawValue) in response.allHeaderFields {
            guard let key = rawKey as? String else { continue }
            let value = String(describing: rawValue)
            let normalizedKey = key.caseInsensitiveCompare("set-cookie") == .orderedSame ? "Set-Cookie" : key
            stringHeaders[normalizedKey] = value
            lowerToValue[key.lowercased()] = value
        }

        var extractedBearer: String?
        for headerName in profile.auth.tokenResponseHeaders {
            if let rawToken = lowerToValue[headerName.lowercased()],
               let cleaned = CredentialSanitizer.cleanBearer(rawToken) {
                extractedBearer = cleaned
                break
            }
        }

        let csrfCookieName = profile.auth.effectiveCsrfCookie()
        let acceptedSessionNames = profile.auth.acceptedSessionCookies()

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

            if cookie.name.caseInsensitiveCompare(csrfCookieName) == .orderedSame {
                extractedCsrf = cleanedValue
            } else if acceptedSessionNames.contains(where: { $0.caseInsensitiveCompare(cookie.name) == .orderedSame }) {
                extractedSessionId = cleanedValue
            }
        }

        // 兜底兼容逗号或分号拼接多条 Cookie（含 expires=Tue, 23-Nov-... 日期逗号）的 Set-Cookie 响应头
        if let rawSetCookie = stringHeaders["Set-Cookie"] {
            if extractedSessionId == nil {
                for candidate in acceptedSessionNames where !rejectedCookieNames.contains(candidate.lowercased()) {
                    if let cleaned = CredentialSanitizer.cleanCookieValue(rawSetCookie, key: candidate) {
                        extractedSessionId = cleaned
                        break
                    }
                }
            }
            if extractedCsrf == nil,
               !rejectedCookieNames.contains(csrfCookieName.lowercased()),
               let cleaned = CredentialSanitizer.cleanCookieValue(rawSetCookie, key: csrfCookieName) {
                extractedCsrf = cleaned
            }
        }

        return ExtractedCredentials(
            bearer: extractedBearer,
            sessionId: extractedSessionId,
            csrfToken: extractedCsrf
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
