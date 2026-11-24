import Foundation

/// 一次扫码登录会话上下文。
struct QrLoginSession: Equatable, Hashable, Sendable {
    let edition: Edition
    let loginToken: String
    let qrContent: String
    let cookies: [String: String]

    init(
        edition: Edition,
        loginToken: String,
        qrContent: String,
        cookies: [String: String] = [:]
    ) {
        self.edition = edition
        self.loginToken = loginToken
        self.qrContent = qrContent
        self.cookies = cookies
    }
}

/// 单步扫码/轮询/验证码接口的归一结果。
enum QrLoginPollOutcome: Equatable, Sendable {
    case pending
    case scanned
    case needsCode(String?)
    case authenticated(Account)
    case expired(String)
    case failed(String)
}

/// 面向 UI 展示的扫码登录状态机阶段。
enum QrLoginStage: Equatable, Sendable {
    case idle
    case loading
    case waitingScan(qrContent: String, loginToken: String)
    case scanned(qrContent: String, loginToken: String)
    case needsCode(loginToken: String, message: String?)
    case verifyingCode
    case succeeded(Account)
    case expired(String)
    case failed(String)
}

enum QrLoginError: Error, LocalizedError, Equatable, Sendable {
    case expired(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .expired(let msg), .failed(let msg):
            return msg
        }
    }
}

/// 扫码登录协议客户端（与 Kotlin `LoginService.kt` 完整对齐）。
final class QrLoginClient: Sendable {
    let client: RainCheckClient
    let profile: ProtocolProfile
    private let stateCache = LoginPreAuthCache()

    init(session: URLSession = .shared, profile: ProtocolProfile = ProtocolCatalog.loadBundled()) {
        self.profile = profile
        self.client = RainCheckClient(session: session, profile: profile)
    }

    /// 1. 发起扫码登录（`loginPre`），保存前置 Set-Cookie 并返回二维码内容与 token。
    func startSession(edition: Edition) async throws -> QrLoginSession {
        let pseudo = pseudoAccount(for: edition)
        let result = await client.callEndpoint("loginPre", account: pseudo, variables: [:])

        if !result.ok {
            let message = result.message ?? "获取登录二维码失败 (HTTP \(result.httpStatus))"
            if (200...299).contains(result.httpStatus) && isExpired(result) {
                throw QrLoginError.expired(message)
            }
            throw QrLoginError.failed(message)
        }

        guard let qrContent = result.firstNonBlankDataString("qrContent", "qr_content", "qrcode", "url"),
              let loginToken = result.firstNonBlankDataString("token", "loginToken", "login_token") else {
            throw QrLoginError.failed("登录响应缺少 qrContent/token: \(String(result.bodyText.prefix(120)))")
        }

        let initialCookies = mergedCookies(base: [:], update: result.responseCookies, auth: result.authUpdate)
        stateCache.save(
            sessionKey: loginToken,
            effectiveToken: loginToken,
            bearer: result.authUpdate?.bearer,
            cookies: initialCookies
        )

        return QrLoginSession(
            edition: edition,
            loginToken: loginToken,
            qrContent: qrContent,
            cookies: initialCookies
        )
    }

    /// 2. 推进扫码等待（`loginWait`），自动透传并累计 `pre-info` 获得的 Cookie。
    func waitForScan(session: QrLoginSession) async -> QrLoginPollOutcome {
        let pseudo = pseudoAccount(for: session.edition)
        let snapshot = stateCache.snapshot(for: session)
        let vars: [String: TemplateValue] = ["loginToken": .string(snapshot.effectiveToken)]

        let wait = await client.callEndpoint(
            "loginWait",
            account: pseudo,
            variables: vars,
            extraCookies: snapshot.cookies
        )

        let updatedCookies = mergedCookies(base: snapshot.cookies, update: wait.responseCookies, auth: wait.authUpdate)
        let updatedBearer = nonEmpty(wait.authUpdate?.bearer) ?? snapshot.bearer
        stateCache.save(
            sessionKey: session.loginToken,
            effectiveToken: snapshot.effectiveToken,
            bearer: updatedBearer,
            cookies: updatedCookies
        )

        if isTransportOrServerError(wait) {
            return .failed(wait.message ?? "查询扫码状态异常 (HTTP \(wait.httpStatus))")
        }
        // 过期优先级高于 needsCode
        if isExpired(wait) {
            stateCache.remove(sessionKey: session.loginToken)
            return .expired(wait.message ?? "二维码已失效")
        }
        if needsCode(wait) {
            let nextToken = verifyToken(of: wait) ?? snapshot.effectiveToken
            stateCache.save(
                sessionKey: session.loginToken,
                effectiveToken: nextToken,
                bearer: updatedBearer,
                cookies: updatedCookies
            )
            return .needsCode(wait.message ?? "扫码成功，需要 4 位验证码")
        }
        if isScanned(wait) {
            return .scanned
        }
        return .pending
    }

    /// 3. 轮询并换取正式会话（`loginPoll`）。
    func pollLogin(session: QrLoginSession) async -> QrLoginPollOutcome {
        let pseudo = pseudoAccount(for: session.edition)
        let snapshot = stateCache.snapshot(for: session)
        let vars: [String: TemplateValue] = ["loginToken": .string(snapshot.effectiveToken)]

        let poll = await client.callEndpoint(
            "loginPoll",
            account: pseudo,
            variables: vars,
            extraCookies: snapshot.cookies
        )

        let updatedCookies = mergedCookies(base: snapshot.cookies, update: poll.responseCookies, auth: poll.authUpdate)
        let updatedBearer = nonEmpty(poll.authUpdate?.bearer) ?? snapshot.bearer
        stateCache.save(
            sessionKey: session.loginToken,
            effectiveToken: snapshot.effectiveToken,
            bearer: updatedBearer,
            cookies: updatedCookies
        )

        if isTransportOrServerError(poll) {
            return .failed(poll.message ?? "登录轮询异常 (HTTP \(poll.httpStatus))")
        }
        if isExpired(poll) {
            stateCache.remove(sessionKey: session.loginToken)
            return .expired(poll.message ?? "二维码已失效")
        }
        if needsCode(poll) {
            let nextToken = verifyToken(of: poll) ?? snapshot.effectiveToken
            stateCache.save(
                sessionKey: session.loginToken,
                effectiveToken: nextToken,
                bearer: updatedBearer,
                cookies: updatedCookies
            )
            return .needsCode(poll.message ?? "扫码成功，需要 4 位验证码")
        }
        if poll.ok {
            let finalized = await finalizeAccount(
                edition: session.edition,
                bearer: updatedBearer,
                cookies: updatedCookies
            )
            stateCache.remove(sessionKey: session.loginToken)
            guard let account = finalized else {
                return .failed("登录响应成功但未返回有效会话凭据（set-auth / Set-Cookie）")
            }
            return .authenticated(account)
        }
        if isScanned(poll) {
            return .scanned
        }
        return .pending
    }

    /// 4. 提交 4 位数字验证码（`loginCode`）；未通过时保留最新 verifyToken 与 Cookie 便于重试。
    func submitCode(session: QrLoginSession, code: String) async -> QrLoginPollOutcome {
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedCode.count == 4, trimmedCode.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return .needsCode("验证码必须是 4 位数字")
        }

        let pseudo = pseudoAccount(for: session.edition)
        let snapshot = stateCache.snapshot(for: session)
        let vars: [String: TemplateValue] = [
            "loginToken": .string(snapshot.effectiveToken),
            "code": .string(trimmedCode)
        ]

        let result = await client.callEndpoint(
            "loginCode",
            account: pseudo,
            variables: vars,
            extraCookies: snapshot.cookies
        )

        let updatedCookies = mergedCookies(base: snapshot.cookies, update: result.responseCookies, auth: result.authUpdate)
        let updatedBearer = nonEmpty(result.authUpdate?.bearer) ?? snapshot.bearer

        if isTransportOrServerError(result) {
            return .failed(result.message ?? "提交验证码网络异常 (HTTP \(result.httpStatus))")
        }
        if isExpired(result) {
            stateCache.remove(sessionKey: session.loginToken)
            return .expired(result.message ?? "二维码已失效")
        }
        if result.ok {
            let finalized = await finalizeAccount(
                edition: session.edition,
                bearer: updatedBearer,
                cookies: updatedCookies
            )
            stateCache.remove(sessionKey: session.loginToken)
            guard let account = finalized else {
                return .failed("验证码校验通过但服务端未返回有效会话凭据")
            }
            return .authenticated(account)
        }

        let nextToken = verifyToken(of: result) ?? snapshot.effectiveToken
        stateCache.save(
            sessionKey: session.loginToken,
            effectiveToken: nextToken,
            bearer: updatedBearer,
            cookies: updatedCookies
        )
        return .needsCode(result.message ?? "验证码未通过，请重新输入")
    }

    /// 5. 组装并验证最终账号：拒绝空凭据；若 `basic-info` 暂时降级，保留已拿到的有效会话。
    func finalizeAccount(edition: Edition, bearer: String?, cookies: [String: String]) async -> Account? {
        let cleanedBearer = bearer.flatMap { CredentialSanitizer.cleanBearer($0) }
        let acceptedSessions = profile.auth.acceptedSessionCookies()
        let csrfKey = profile.auth.effectiveCsrfCookie()

        var sessionId: String?
        for candidateName in acceptedSessions {
            if let matched = cookies.first(where: { $0.key.caseInsensitiveCompare(candidateName) == .orderedSame }),
               let cleaned = nonEmpty(matched.value) {
                sessionId = cleaned
                break
            }
        }

        let csrfToken = cookies.first(where: {
            $0.key.caseInsensitiveCompare(csrfKey) == .orderedSame
        }).flatMap { nonEmpty($0.value) }

        // 严格拒绝空凭据（仅含 csrftoken 亦不足以作为主会话凭据）
        guard cleanedBearer != nil || sessionId != nil else {
            return nil
        }

        let accountId = UUID().uuidString
        let now = RainCheckTime.nowMillis()
        let fallbackLabel = "账号 \(accountId.prefix(4))"

        let candidate = Account(
            id: accountId,
            label: fallbackLabel,
            host: edition.host,
            scheme: edition.scheme,
            bearer: cleanedBearer,
            sessionId: sessionId,
            csrfToken: csrfToken,
            enabled: true,
            createdAt: now,
            lastOkAt: nil,
            userId: nil,
            note: ""
        )

        do {
            let verified = try await client.fetchMe(account: candidate)
            var enriched = verified.refreshedAccount ?? candidate
            if let name = nonEmpty(verified.name) {
                enriched.label = name
            }
            if let uid = nonEmpty(verified.userId) {
                enriched.userId = uid
            }
            enriched.lastOkAt = RainCheckTime.nowMillis()
            return enriched
        } catch {
            // `basic-info` 降级时仍保留刚获取到的有效会话凭据，避免用户白扫一次
            return candidate
        }
    }

    // MARK: - Protocol State Detection

    private func pseudoAccount(for edition: Edition) -> Account {
        Account(
            id: "login-\(edition.id)",
            label: "登录",
            host: edition.host,
            scheme: edition.scheme
        )
    }

    private func needsCode(_ result: ApiCallResult) -> Bool {
        if result.ok { return false }
        if verifyToken(of: result) != nil { return true }
        if result.dataValue("needCode")?.boolValue == true
            || result.dataValue("need_code")?.boolValue == true {
            return true
        }
        if let msg = result.message, msg.localizedCaseInsensitiveContains("验证码") {
            return true
        }
        return false
    }

    private func isScanned(_ result: ApiCallResult) -> Bool {
        if result.dataValue("scanned")?.boolValue == true {
            return true
        }
        if let status = result.firstNonBlankDataString("status", "state"),
           status.caseInsensitiveCompare("scanned") == .orderedSame {
            return true
        }
        let msg = result.message ?? ""
        return msg.contains("已扫码") || msg.contains("待确认")
    }

    private func verifyToken(of result: ApiCallResult) -> String? {
        result.firstNonBlankDataString(
            "token",
            "verify_token",
            "verifyToken",
            "need_code_token",
            "needCodeToken"
        )
    }

    private func isTransportOrServerError(_ result: ApiCallResult) -> Bool {
        if result.httpStatus <= 0 || result.httpStatus == 404 {
            return true
        }
        if result.httpStatus >= 500 {
            let msg = result.message ?? ""
            return !matchesExpiredKeyword(msg)
        }
        return false
    }

    private func isExpired(_ result: ApiCallResult) -> Bool {
        if result.httpStatus == 401 || result.httpStatus == 403 {
            return true
        }
        if let code = result.businessCode, code == 50000 || code == 50001 {
            return true
        }
        return matchesExpiredKeyword(result.message ?? "")
    }

    private func matchesExpiredKeyword(_ text: String) -> Bool {
        let lower = text.lowercased()
        guard !lower.isEmpty else { return false }
        return profile.result.expiredKeywords.contains { kw in
            let trimmed = kw.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && lower.contains(trimmed.lowercased())
        }
    }

    private func mergedCookies(
        base: [String: String],
        update: [String: String],
        auth: AuthUpdate?
    ) -> [String: String] {
        var merged = base
        for (k, v) in update {
            if let cleaned = nonEmpty(v) {
                merged[k] = cleaned
            }
        }
        if let sid = nonEmpty(auth?.sessionId) {
            merged[profile.auth.primarySessionCookie()] = sid
        }
        if let csrf = nonEmpty(auth?.csrfToken) {
            merged[profile.auth.effectiveCsrfCookie()] = csrf
        }
        return merged
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// 线程安全、容量受控（最多 32 条）的扫码登录前置会话状态缓存。
private final class LoginPreAuthCache: @unchecked Sendable {
    struct Entry: Sendable {
        var effectiveToken: String
        var bearer: String?
        var cookies: [String: String]
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var insertionOrder: [String] = []
    private let maxEntries = 32

    func snapshot(for session: QrLoginSession) -> Entry {
        lock.lock()
        defer { lock.unlock() }
        if var existing = entries[session.loginToken] {
            var mergedCookies = session.cookies
            for (k, v) in existing.cookies {
                mergedCookies[k] = v
            }
            existing.cookies = mergedCookies
            return existing
        }
        return Entry(
            effectiveToken: session.loginToken,
            bearer: nil,
            cookies: session.cookies
        )
    }

    func save(
        sessionKey: String,
        effectiveToken: String,
        bearer: String?,
        cookies: [String: String]
    ) {
        lock.lock()
        defer { lock.unlock() }
        if entries[sessionKey] == nil {
            if insertionOrder.count >= maxEntries, let oldest = insertionOrder.first {
                insertionOrder.removeFirst()
                entries.removeValue(forKey: oldest)
            }
            insertionOrder.append(sessionKey)
        }
        entries[sessionKey] = Entry(
            effectiveToken: effectiveToken,
            bearer: bearer,
            cookies: cookies
        )
    }

    func remove(sessionKey: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeValue(forKey: sessionKey)
        insertionOrder.removeAll { $0 == sessionKey }
    }
}
