package cn.raincheck.core

import io.ktor.http.HttpHeaders
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive

/**
 * 扫码登录流程（替代官方客户端登录）：
 *
 * ```
 * GET  /api/v3/user/login/pre-info        -> qrContent + token (+ Set-Cookie)
 * POST /api/v3/user/login/wait-for-scan   {"token": ...}
 * POST /api/v3/user/login                 {"token": ...}        code==0 即登录完成
 * POST /api/v3/user/login/login-with-code {"token":..., "code": 4位}
 * GET  /api/v3/user/basic-info            校验并取回昵称/uid
 * ```
 *
 * 每个账号用各自的微信扫自己的码，扫完即写入账号池；二维码过期重新 [start]。
 */
class LoginService(
    private val api: RainCheckApi,
    private val profile: ProtocolProfile,
) {
    private val preAuthMutex = Mutex()
    private val preSessionAuth = LinkedHashMap<String, AuthUpdate>()

    /** 发起一次扫码登录，返回需要渲染的二维码内容。 */
    suspend fun start(edition: Edition): LoginPoll {
        val pseudo = Account(
            id = "login-${edition.id}",
            label = "登录",
            host = edition.host,
            scheme = edition.scheme,
        )
        val result = api.call(pseudo, "loginPre")
        if (!result.ok) {
            val state = if (result.httpStatus in 200..299 && isExpired(result)) {
                LoginState.EXPIRED
            } else {
                LoginState.ERROR
            }
            return LoginPoll(
                state = state,
                message = result.message ?: "获取登录二维码失败 (HTTP ${result.httpStatus})",
            )
        }
        val data = result.data()
        val qrContent = data?.firstNonBlankString("qrContent", "qr_content", "qrcode", "url")
        val loginToken = data?.firstNonBlankString("token", "loginToken", "login_token")
        if (qrContent.isNullOrBlank() || loginToken.isNullOrBlank()) {
            return LoginPoll(
                state = LoginState.ERROR,
                message = "登录响应缺少 qrContent/token: ${result.body.take(120)}",
            )
        }
        result.auth?.takeIf { !it.isEmpty }?.let { auth ->
            savePreAuth(loginToken, auth)
        }
        return LoginPoll(
            state = LoginState.PENDING,
            message = "请用该账号的微信扫码",
            loginToken = loginToken,
            qrContent = qrContent,
        )
    }

    /** 轮询扫码状态；扫完返回带会话的 [Account]。 */
    suspend fun poll(
        edition: Edition,
        loginToken: String,
        existing: Account? = null,
    ): LoginPoll {
        val pseudo = (existing ?: Account(
            id = "login-${edition.id}",
            label = "登录",
            host = edition.host,
            scheme = edition.scheme,
        )).copy(host = edition.host, scheme = edition.scheme)

        val vars = mapOf<String, JsonElement>(
            "loginToken" to JsonPrimitive(loginToken),
        )

        val preAuth = getPreAuth(loginToken)

        // 1. wait-for-scan：推进扫码状态或触发验证码
        val wait = api.call(pseudo, "loginWait", vars, extraHeaders = buildPreCookieHeaders(preAuth))
        val afterWaitAuth = mergeAuth(preAuth, wait.auth)
        if (afterWaitAuth != null && afterWaitAuth != preAuth) {
            savePreAuth(loginToken, afterWaitAuth)
        }

        if (isTransportOrServerError(wait)) {
            return LoginPoll(
                state = LoginState.ERROR,
                message = wait.message ?: "查询扫码状态异常 (HTTP ${wait.httpStatus})",
                loginToken = loginToken,
            )
        }
        // isExpired 优先级高于 needsCode
        if (isExpired(wait)) {
            removePreAuth(loginToken)
            return LoginPoll(LoginState.EXPIRED, wait.message ?: "二维码已失效", loginToken = loginToken)
        }
        if (needsCode(wait)) {
            val nextToken = verifyTokenOf(wait) ?: loginToken
            if (nextToken != loginToken && afterWaitAuth != null) {
                savePreAuth(nextToken, afterWaitAuth)
            }
            return LoginPoll(
                state = LoginState.NEED_CODE,
                message = wait.message ?: "扫码成功，需要 4 位验证码",
                loginToken = nextToken,
            )
        }

        val waitScanned = isScanned(wait)

        // 2. 真正换会话
        val poll = api.call(pseudo, "loginPoll", vars, extraHeaders = buildPreCookieHeaders(afterWaitAuth))
        val combinedAuth = mergeAuth(afterWaitAuth, poll.auth)
        if (combinedAuth != null && combinedAuth != afterWaitAuth) {
            savePreAuth(loginToken, combinedAuth)
        }

        if (isTransportOrServerError(poll)) {
            return LoginPoll(
                state = LoginState.ERROR,
                message = poll.message ?: "登录轮询异常 (HTTP ${poll.httpStatus})",
                loginToken = loginToken,
            )
        }
        if (isExpired(poll)) {
            removePreAuth(loginToken)
            return LoginPoll(LoginState.EXPIRED, poll.message ?: "二维码已失效", loginToken = loginToken)
        }
        if (needsCode(poll)) {
            val nextToken = verifyTokenOf(poll) ?: loginToken
            if (nextToken != loginToken && combinedAuth != null) {
                savePreAuth(nextToken, combinedAuth)
            }
            return LoginPoll(
                state = LoginState.NEED_CODE,
                message = poll.message ?: "扫码成功，需要 4 位验证码",
                loginToken = nextToken,
            )
        }
        if (poll.ok) {
            val account = finishLogin(pseudo, combinedAuth, existing)
            removePreAuth(loginToken)
            if (account == null) {
                return LoginPoll(
                    state = LoginState.ERROR,
                    message = "登录响应成功但未返回有效会话凭据（set-auth / Set-Cookie）",
                    loginToken = loginToken,
                )
            }
            return LoginPoll(
                state = LoginState.AUTHORIZED,
                message = "登录成功",
                loginToken = loginToken,
                account = account,
            )
        }
        if (waitScanned || isScanned(poll)) {
            return LoginPoll(
                state = LoginState.SCANNED,
                message = wait.message?.takeIf { it.isNotBlank() }
                    ?: poll.message?.takeIf { it.isNotBlank() }
                    ?: "已扫码，请在微信中确认登录",
                loginToken = loginToken,
            )
        }
        return LoginPoll(
            state = LoginState.PENDING,
            message = poll.message?.takeIf { it.isNotBlank() }
                ?: wait.message?.takeIf { it.isNotBlank() }
                ?: "等待扫码",
            loginToken = loginToken,
        )
    }

    /** 需要验证码时提交 4 位数字；校验未通过时返回 [LoginState.NEED_CODE] 并保留 verifyToken 便于重试。 */
    suspend fun submitCode(
        edition: Edition,
        loginToken: String,
        code: String,
        existing: Account? = null,
    ): LoginPoll {
        if (code.length != 4 || code.any { !it.isDigit() }) {
            return LoginPoll(LoginState.NEED_CODE, "验证码必须是 4 位数字", loginToken = loginToken)
        }
        val pseudo = (existing ?: Account(
            id = "login-${edition.id}",
            label = "登录",
            host = edition.host,
            scheme = edition.scheme,
        )).copy(host = edition.host, scheme = edition.scheme)

        val vars = mapOf<String, JsonElement>(
            "loginToken" to JsonPrimitive(loginToken),
            "code" to JsonPrimitive(code),
        )
        val preAuth = getPreAuth(loginToken)
        val result = api.call(pseudo, "loginCode", vars, extraHeaders = buildPreCookieHeaders(preAuth))
        val combinedAuth = mergeAuth(preAuth, result.auth)

        if (isTransportOrServerError(result)) {
            return LoginPoll(
                state = LoginState.ERROR,
                message = result.message ?: "提交验证码网络异常 (HTTP ${result.httpStatus})",
                loginToken = loginToken,
            )
        }
        if (isExpired(result)) {
            removePreAuth(loginToken)
            return LoginPoll(LoginState.EXPIRED, result.message ?: "二维码已失效", loginToken = loginToken)
        }
        if (result.ok) {
            val account = finishLogin(pseudo, combinedAuth, existing)
            removePreAuth(loginToken)
            if (account == null) {
                return LoginPoll(
                    state = LoginState.ERROR,
                    message = "验证码校验通过但服务端未返回有效会话凭据",
                    loginToken = loginToken,
                )
            }
            return LoginPoll(LoginState.AUTHORIZED, "登录成功", loginToken = loginToken, account = account)
        }
        val nextToken = verifyTokenOf(result) ?: loginToken
        if (nextToken != loginToken && combinedAuth != null) {
            savePreAuth(nextToken, combinedAuth)
        }
        return LoginPoll(
            state = LoginState.NEED_CODE,
            message = result.message ?: "验证码未通过，请重新输入",
            loginToken = nextToken,
        )
    }

    /** 校验账号会话，吸收 `me.auth` 回填并返回带昵称/uid 的账号（失败返回 null）。 */
    suspend fun verify(account: Account): Account? {
        val me = api.call(account, "me")
        if (!me.ok) return null
        val refreshed = me.auth?.applyTo(account, markOk = true) ?: account
        val data = me.data()
        val label = data?.firstNonBlankString("name", "userName", "nickname", "username") ?: refreshed.label
        val uid = data?.firstNonBlankString("id", "userId", "user_id")
        return refreshed.copy(
            label = label.takeIf { it.isNotBlank() } ?: refreshed.label,
            userId = uid ?: refreshed.userId,
            lastOkAt = nowMillis(),
        )
    }

    // ---------------------------------------------------------------- 内部

    private suspend fun finishLogin(
        pseudo: Account,
        auth: AuthUpdate?,
        existing: Account?,
    ): Account? {
        if (auth == null || auth.isEmpty) return null
        val hasPrimaryCredential = !auth.bearer.isNullOrBlank() || !auth.sessionId.isNullOrBlank()
        if (!hasPrimaryCredential) return null

        val now = nowMillis()
        val base = existing?.copy(host = pseudo.host, scheme = pseudo.scheme) ?: pseudo.copy(
            id = randomId(),
            label = "账号 ${randomId().take(4)}",
            createdAt = now,
        )
        val withAuth = auth.applyTo(base, markOk = false)
        if (!withAuth.hasCredential) return null
        // basic-info 用于补昵称/uid 与验证会话；即使它暂时不可用，只要刚拿到有效凭据仍先入池，避免白扫一次
        return verify(withAuth) ?: withAuth
    }

    private fun needsCode(result: ApiResult): Boolean {
        if (result.ok) return false
        val data = result.data()
        val hasVerifyToken = data?.firstNonBlankString(
            "token", "verify_token", "verifyToken", "need_code_token", "needCodeToken",
        ) != null
        val needFlag = data?.get("needCode").asNonNullBoolOrNull() == true ||
            data?.get("need_code").asNonNullBoolOrNull() == true
        val msgHint = result.message?.contains("验证码", ignoreCase = true) == true
        return hasVerifyToken || needFlag || msgHint
    }

    private fun isScanned(result: ApiResult): Boolean {
        val data = result.data()
        if (data?.get("scanned").asNonNullBoolOrNull() == true) return true
        val status = data?.firstNonBlankString("status", "state")
        if (status != null && status.equals("scanned", ignoreCase = true)) return true
        val msg = result.message.orEmpty()
        return msg.contains("已扫码") || msg.contains("待确认")
    }

    private fun verifyTokenOf(result: ApiResult): String? {
        val data = result.data() ?: return null
        return data.firstNonBlankString("token", "verify_token", "verifyToken", "need_code_token", "needCodeToken")
    }

    private fun isTransportOrServerError(result: ApiResult): Boolean {
        if (result.httpStatus <= 0 || result.httpStatus == 404) return true
        if (result.httpStatus >= 500) {
            val message = result.message.orEmpty()
            return !profile.result.expiredKeywords.any { kw -> kw.isNotBlank() && message.contains(kw, ignoreCase = true) }
        }
        return false
    }

    private fun isExpired(result: ApiResult): Boolean {
        val status = result.httpStatus
        if (status == 401 || status == 403) return true
        if (result.code in listOf(50000, 50001)) return true
        val message = result.message.orEmpty()
        return profile.result.expiredKeywords.any { kw -> kw.isNotBlank() && message.contains(kw, ignoreCase = true) }
    }

    private fun buildPreCookieHeaders(auth: AuthUpdate?): Map<String, String> {
        if (auth == null) return emptyMap()
        val sessionName = profile.auth.primarySessionCookie()
        val csrfName = profile.auth.effectiveCsrfCookie()
        val cookies = buildList {
            auth.sessionId?.takeIf { it.isNotBlank() }?.let { add("$sessionName=$it") }
            auth.csrfToken?.takeIf { it.isNotBlank() }?.let { add("$csrfName=$it") }
        }
        return buildMap {
            if (cookies.isNotEmpty()) put(HttpHeaders.Cookie, cookies.joinToString("; "))
            auth.csrfToken?.takeIf { it.isNotBlank() }?.let { put(profile.auth.csrfHeader, it) }
        }
    }

    private fun mergeAuth(first: AuthUpdate?, second: AuthUpdate?): AuthUpdate? {
        if (first == null) return second
        if (second == null) return first
        val merged = AuthUpdate(
            bearer = second.bearer?.takeIf { it.isNotBlank() } ?: first.bearer,
            sessionId = second.sessionId?.takeIf { it.isNotBlank() } ?: first.sessionId,
            csrfToken = second.csrfToken?.takeIf { it.isNotBlank() } ?: first.csrfToken,
        )
        return if (merged.isEmpty) null else merged
    }

    private suspend fun savePreAuth(token: String, auth: AuthUpdate) {
        preAuthMutex.withLock {
            if (preSessionAuth.size >= 32 && !preSessionAuth.containsKey(token)) {
                val oldest = preSessionAuth.keys.firstOrNull()
                if (oldest != null) preSessionAuth.remove(oldest)
            }
            preSessionAuth[token] = auth
        }
    }

    private suspend fun getPreAuth(token: String): AuthUpdate? = preAuthMutex.withLock {
        preSessionAuth[token]
    }

    private suspend fun removePreAuth(token: String) {
        preAuthMutex.withLock {
            preSessionAuth.remove(token)
        }
    }
}
