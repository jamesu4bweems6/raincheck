//
//  LoginService.swift
//  RainCheck
//
//  扫码登录服务，与 `core/src/commonMain/kotlin/cn/raincheck/core/LoginService.kt` 100% 行为对齐：
//   - 用 actor 并发安全缓存 `pre-info` / `wait-for-scan` 期间下发的 Cookie/CSRF；
//   - 完整实现 `SCANNED` 与 `NEED_CODE`（4 位验证码）流转，错码保持 `NEED_CODE` 与 `verifyToken` 便于重试；
//   - `start()` 遇到 404/500/网络异常返回 `ERROR`；
//   - `finishLogin` 先校验 `hasCredential`（绝不伪造无凭据 `AUTHORIZED`），
//     拿到有效凭据后尝试 `basic-info` 校验，若校验暂时不可用仍保留会话入池（与 Kotlin 一致）；
//   - `verify()` 吸收 `me.auth` 会话刷新并回填昵称 / uid。
//

import Foundation

private actor PreAuthCache {
    private var order: [String] = []
    private var entries: [String: AuthUpdate] = [:]

    func get(_ token: String) -> AuthUpdate? {
        entries[token]
    }

    func save(_ token: String, auth: AuthUpdate) {
        if entries[token] == nil {
            if order.count >= 32, let oldest = order.first {
                order.removeFirst()
                entries.removeValue(forKey: oldest)
            }
            order.append(token)
        }
        entries[token] = auth
    }

    func remove(_ token: String) {
        entries.removeValue(forKey: token)
        order.removeAll { $0 == token }
    }
}

final class LoginService: Sendable {
    private let api: RainCheckApi
    private let profile: ProtocolProfile
    private let preAuthCache = PreAuthCache()

    private let codeTokenKeys = ["token", "verify_token", "verifyToken", "need_code_token", "needCodeToken"]

    init(api: RainCheckApi, profile: ProtocolProfile) {
        self.api = api
        self.profile = profile
    }

    // MARK: 发起扫码登录

    func start(edition: Edition) async -> LoginPoll {
        let pseudo = Account(
            id: "login-\(edition.id)",
            label: "登录",
            host: edition.host,
            scheme: edition.scheme
        )
        let result = await api.call(account: pseudo, endpointName: "loginPre")
        if !result.ok {
            let state: LoginState = ((200...299).contains(result.httpStatus) && isExpired(result)) ? .EXPIRED : .ERROR
            return LoginPoll(
                state: state,
                message: result.message?.trimmedNonEmpty ?? "获取登录二维码失败 (HTTP \(result.httpStatus))"
            )
        }
        guard let data = result.data(),
              let qrContent = JSONAssist.firstString(data, ["qrContent", "qr_content", "qrcode", "url"]),
              let loginToken = JSONAssist.firstString(data, ["token", "loginToken", "login_token"]) else {
            return LoginPoll(
                state: .ERROR,
                message: "登录响应缺少 qrContent / token：\(String(result.body.prefix(120)))"
            )
        }
        if let auth = result.auth, !auth.isEmpty {
            await preAuthCache.save(loginToken, auth: auth)
        }
        return LoginPoll(
            state: .PENDING,
            message: "请用该账号的微信扫码",
            loginToken: loginToken,
            qrContent: qrContent
        )
    }

    // MARK: 轮询扫码状态

    func poll(edition: Edition, loginToken: String, existing: Account? = nil) async -> LoginPoll {
        var pseudo = existing ?? Account(
            id: "login-\(edition.id)",
            label: "登录",
            host: edition.host,
            scheme: edition.scheme
        )
        pseudo.host = edition.host
        pseudo.scheme = edition.scheme

        let vars: [String: JSONValue] = ["loginToken": .string(loginToken)]
        let preAuth = await preAuthCache.get(loginToken)

        // 1. wait-for-scan
        let wait = await api.call(
            account: pseudo,
            endpointName: "loginWait",
            vars: vars,
            extraHeaders: buildPreCookieHeaders(preAuth)
        )
        let afterWaitAuth = mergeAuth(preAuth, wait.auth)
        if let afterWaitAuth, afterWaitAuth != preAuth {
            await preAuthCache.save(loginToken, auth: afterWaitAuth)
        }

        if isTransportOrServerError(wait) {
            return LoginPoll(
                state: .ERROR,
                message: wait.message?.trimmedNonEmpty ?? "查询扫码状态异常 (HTTP \(wait.httpStatus))",
                loginToken: loginToken
            )
        }
        if isExpired(wait) {
            await preAuthCache.remove(loginToken)
            return LoginPoll(
                state: .EXPIRED,
                message: wait.message?.trimmedNonEmpty ?? "二维码已失效",
                loginToken: loginToken
            )
        }
        if needsCode(wait) {
            let nextToken = verifyTokenOf(wait) ?? loginToken
            if nextToken != loginToken, let afterWaitAuth {
                await preAuthCache.save(nextToken, auth: afterWaitAuth)
            }
            return LoginPoll(
                state: .NEED_CODE,
                message: wait.message?.trimmedNonEmpty ?? "扫码成功，需要 4 位验证码",
                loginToken: nextToken
            )
        }

        let waitScanned = isScanned(wait)

        // 2. loginPoll
        let poll = await api.call(
            account: pseudo,
            endpointName: "loginPoll",
            vars: vars,
            extraHeaders: buildPreCookieHeaders(afterWaitAuth)
        )
        let combinedAuth = mergeAuth(afterWaitAuth, poll.auth)
        if let combinedAuth, combinedAuth != afterWaitAuth {
            await preAuthCache.save(loginToken, auth: combinedAuth)
        }

        if isTransportOrServerError(poll) {
            return LoginPoll(
                state: .ERROR,
                message: poll.message?.trimmedNonEmpty ?? "登录轮询异常 (HTTP \(poll.httpStatus))",
                loginToken: loginToken
            )
        }
        if isExpired(poll) {
            await preAuthCache.remove(loginToken)
            return LoginPoll(
                state: .EXPIRED,
                message: poll.message?.trimmedNonEmpty ?? "二维码已失效",
                loginToken: loginToken
            )
        }
        if needsCode(poll) {
            let nextToken = verifyTokenOf(poll) ?? loginToken
            if nextToken != loginToken, let combinedAuth {
                await preAuthCache.save(nextToken, auth: combinedAuth)
            }
            return LoginPoll(
                state: .NEED_CODE,
                message: poll.message?.trimmedNonEmpty ?? "扫码成功，需要 4 位验证码",
                loginToken: nextToken
            )
        }
        if poll.ok {
            let account = await finishLogin(pseudo: pseudo, auth: combinedAuth, existing: existing)
            await preAuthCache.remove(loginToken)
            guard let account else {
                return LoginPoll(
                    state: .ERROR,
                    message: "登录响应成功但未返回有效会话凭据（set-auth / Set-Cookie）",
                    loginToken: loginToken
                )
            }
            return LoginPoll(
                state: .AUTHORIZED,
                message: "登录成功",
                loginToken: loginToken,
                account: account
            )
        }
        if waitScanned || isScanned(poll) {
            return LoginPoll(
                state: .SCANNED,
                message: wait.message?.trimmedNonEmpty
                    ?? poll.message?.trimmedNonEmpty
                    ?? "已扫码，请在微信中确认登录",
                loginToken: loginToken
            )
        }
        return LoginPoll(
            state: .PENDING,
            message: poll.message?.trimmedNonEmpty
                ?? wait.message?.trimmedNonEmpty
                ?? "等待扫码",
            loginToken: loginToken
        )
    }

    // MARK: 提交 4 位验证码

    func submitCode(
        edition: Edition,
        loginToken: String,
        code: String,
        existing: Account? = nil
    ) async -> LoginPoll {
        let digits = code.trimmed
        guard digits.count == 4, digits.allSatisfy({ $0.isNumber }) else {
            return LoginPoll(state: .NEED_CODE, message: "验证码必须是 4 位数字", loginToken: loginToken)
        }

        var pseudo = existing ?? Account(
            id: "login-\(edition.id)",
            label: "登录",
            host: edition.host,
            scheme: edition.scheme
        )
        pseudo.host = edition.host
        pseudo.scheme = edition.scheme

        let vars: [String: JSONValue] = [
            "loginToken": .string(loginToken),
            "code": .string(digits)
        ]
        let preAuth = await preAuthCache.get(loginToken)
        let result = await api.call(
            account: pseudo,
            endpointName: "loginCode",
            vars: vars,
            extraHeaders: buildPreCookieHeaders(preAuth)
        )
        let combinedAuth = mergeAuth(preAuth, result.auth)

        if isTransportOrServerError(result) {
            return LoginPoll(
                state: .ERROR,
                message: result.message?.trimmedNonEmpty ?? "提交验证码网络异常 (HTTP \(result.httpStatus))",
                loginToken: loginToken
            )
        }
        if isExpired(result) {
            await preAuthCache.remove(loginToken)
            return LoginPoll(
                state: .EXPIRED,
                message: result.message?.trimmedNonEmpty ?? "二维码已失效",
                loginToken: loginToken
            )
        }
        if result.ok {
            let account = await finishLogin(pseudo: pseudo, auth: combinedAuth, existing: existing)
            await preAuthCache.remove(loginToken)
            guard let account else {
                return LoginPoll(
                    state: .ERROR,
                    message: "验证码校验通过但服务端未返回有效会话凭据",
                    loginToken: loginToken
                )
            }
            return LoginPoll(
                state: .AUTHORIZED,
                message: "登录成功",
                loginToken: loginToken,
                account: account
            )
        }

        let nextToken = verifyTokenOf(result) ?? loginToken
        if nextToken != loginToken, let combinedAuth {
            await preAuthCache.save(nextToken, auth: combinedAuth)
        }
        return LoginPoll(
            state: .NEED_CODE,
            message: result.message?.trimmedNonEmpty ?? "验证码未通过，请重新输入",
            loginToken: nextToken
        )
    }

    // MARK: 校验并吸收会话刷新

    func verify(account: Account) async -> Account? {
        let me = await api.call(account: account, endpointName: "me")
        guard me.ok else { return nil }
        var copy = me.auth?.applyTo(account, markOk: true) ?? account
        if let data = me.data() {
            if let name = JSONAssist.firstString(data, ["name", "userName", "nickname", "username"]) {
                copy.label = name
            }
            if let uid = JSONAssist.firstString(data, ["id", "userId", "user_id"]) {
                copy.userId = uid
            }
        }
        copy.lastOkAt = TimeUtil.nowMillis()
        return copy
    }

    // MARK: 内部辅助

    private func finishLogin(pseudo: Account, auth: AuthUpdate?, existing: Account?) async -> Account? {
        guard let auth, !auth.isEmpty else { return nil }
        let hasPrimary = (auth.bearer?.trimmedNonEmpty != nil) || (auth.sessionId?.trimmedNonEmpty != nil)
        guard hasPrimary else { return nil }

        var base: Account
        if var existing {
            existing.host = pseudo.host
            existing.scheme = pseudo.scheme
            base = existing
        } else {
            base = Account(
                id: Ids.randomId(),
                label: "账号 \(Ids.shortId())",
                host: pseudo.host,
                scheme: pseudo.scheme,
                createdAt: TimeUtil.nowMillis()
            )
        }
        let withAuth = auth.applyTo(base, markOk: false)
        guard withAuth.hasCredential else { return nil }
        // 与 Kotlin 一致：basic-info 校验成功则补全昵称/uid，若暂时失败仍保留刚拿到的有效会话
        return await verify(account: withAuth) ?? withAuth
    }

    private func needsCode(_ result: ApiResult) -> Bool {
        if result.ok { return false }
        let data = result.data()
        let hasVerifyToken = data.flatMap { JSONAssist.firstString($0, codeTokenKeys) } != nil
        let needFlag = (data?["needCode"]?.nonNullBool == true) || (data?["need_code"]?.nonNullBool == true)
        let msgHint = result.message?.localizedCaseInsensitiveContains("验证码") == true
        return hasVerifyToken || needFlag || msgHint
    }

    private func isScanned(_ result: ApiResult) -> Bool {
        let data = result.data()
        if data?["scanned"]?.nonNullBool == true { return true }
        if let status = data.flatMap({ JSONAssist.firstString($0, ["status", "state"]) }),
           status.caseInsensitiveCompare("scanned") == .orderedSame {
            return true
        }
        let msg = result.message ?? ""
        return msg.contains("已扫码") || msg.contains("待确认")
    }

    private func verifyTokenOf(_ result: ApiResult) -> String? {
        result.data().flatMap { JSONAssist.firstString($0, codeTokenKeys) }
    }

    private func isTransportOrServerError(_ result: ApiResult) -> Bool {
        if result.httpStatus <= 0 || result.httpStatus == 404 { return true }
        if result.httpStatus >= 500 {
            let msg = result.message ?? ""
            let lower = msg.lowercased()
            let hasExpired = profile.result.expiredKeywords.contains { kw in
                guard let clean = kw.trimmedNonEmpty else { return false }
                return lower.contains(clean.lowercased())
            }
            return !hasExpired
        }
        return false
    }

    private func isExpired(_ result: ApiResult) -> Bool {
        if result.httpStatus == 401 || result.httpStatus == 403 { return true }
        if let code = result.code, code == 50000 || code == 50001 { return true }
        let msg = (result.message ?? "").lowercased()
        return profile.result.expiredKeywords.contains { kw in
            guard let clean = kw.trimmedNonEmpty else { return false }
            return msg.contains(clean.lowercased())
        }
    }

    private func buildPreCookieHeaders(_ auth: AuthUpdate?) -> [String: String] {
        guard let auth else { return [:] }
        let sessionName = profile.auth.primarySessionCookie
        let csrfName = profile.auth.effectiveCsrfCookie
        var cookies: [String] = []
        if let sid = auth.sessionId?.trimmedNonEmpty {
            cookies.append("\(sessionName)=\(sid)")
        }
        if let csrf = auth.csrfToken?.trimmedNonEmpty {
            cookies.append("\(csrfName)=\(csrf)")
        }
        var headers: [String: String] = [:]
        if !cookies.isEmpty {
            headers["Cookie"] = cookies.joined(separator: "; ")
        }
        if let csrf = auth.csrfToken?.trimmedNonEmpty {
            headers[profile.auth.csrfHeader] = csrf
        }
        return headers
    }

    private func mergeAuth(_ first: AuthUpdate?, _ second: AuthUpdate?) -> AuthUpdate? {
        guard let first else { return second }
        guard let second else { return first }
        let merged = AuthUpdate(
            bearer: second.bearer?.trimmedNonEmpty ?? first.bearer,
            sessionId: second.sessionId?.trimmedNonEmpty ?? first.sessionId,
            csrfToken: second.csrfToken?.trimmedNonEmpty ?? first.csrfToken
        )
        return merged.isEmpty ? nil : merged
    }
}
