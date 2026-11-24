package cn.raincheck.core

import io.ktor.client.HttpClient
import io.ktor.client.HttpClientConfig
import io.ktor.client.plugins.HttpTimeout
import io.ktor.client.request.HttpRequestBuilder
import io.ktor.client.request.request
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.content.TextContent
import io.ktor.http.encodeURLParameter
import io.ktor.http.withCharset
import io.ktor.utils.io.charsets.Charsets
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject

/**
 * 平台托管引擎工厂：由 `HttpClient(OkHttp)` / `HttpClient(Darwin)` 构造，
 * 保持 `manageEngine = true`，确保 `api.close()` 完整关闭底层线程池与连接池无泄漏。
 */
internal expect fun createPlatformHttpClient(config: HttpClientConfig<*>.() -> Unit): HttpClient

internal fun createHttpClient(): HttpClient = createPlatformHttpClient {
    expectSuccess = false
    followRedirects = true
    install(HttpTimeout) {
        requestTimeoutMillis = 25_000
        connectTimeoutMillis = 8_000
        socketTimeoutMillis = 25_000
    }
}

/** 服务端回填的会话材料（`set-auth` 头、Set-Cookie）。 */
data class AuthUpdate(
    val bearer: String? = null,
    val sessionId: String? = null,
    val csrfToken: String? = null,
) {
    val isEmpty: Boolean
        get() = bearer.isNullOrBlank() && sessionId.isNullOrBlank() && csrfToken.isNullOrBlank()

    /**
     * 将新会话材料合入账号；仅在 [markOk] 为 true（成功响应）时刷新 [Account.lastOkAt]，
     * 避免失败响应误刷活跃时间戳。
     */
    fun applyTo(account: Account, markOk: Boolean = false): Account = account.copy(
        bearer = bearer?.takeIf { it.isNotBlank() } ?: account.bearer,
        sessionId = sessionId?.takeIf { it.isNotBlank() } ?: account.sessionId,
        csrfToken = csrfToken?.takeIf { it.isNotBlank() } ?: account.csrfToken,
        lastOkAt = if (markOk) nowMillis() else account.lastOkAt,
    )
}

/**
 * 雨课堂 HTTP 客户端。
 *
 * 只做三件事：拼 URL、拼 Header（含双载体鉴权）、把响应归一成 [ApiResult]。
 * 业务语义全部交给 [SignInEngine] / [LoginService]，方便单测替换 engine。
 */
class RainCheckApi(
    private val profile: ProtocolProfile,
    private val client: HttpClient = createHttpClient(),
) {
    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        explicitNulls = false
    }

    fun close() = client.close()

    // ---------------------------------------------------------------- 业务入口

    suspend fun call(
        account: Account,
        endpointName: String,
        vars: Map<String, JsonElement> = emptyMap(),
        referer: String? = null,
        extraHeaders: Map<String, String> = emptyMap(),
    ): ApiResult {
        val endpoint = profile.endpoint(endpointName)
        val base = baseUrl(account)
        val path = Template.renderPath(endpoint.path, vars)
        val query = Template.renderMap(endpoint.query, vars)
        val url = buildUrl(base, path, query)
        val body = endpoint.body?.let { Template.renderBody(it, vars) }
        return execute(
            account = if (endpoint.auth) account else null,
            method = endpoint.method,
            url = url,
            body = body,
            referer = referer,
            extraHeaders = extraHeaders,
        )
    }

    suspend fun raw(
        account: Account?,
        method: String,
        url: String,
        body: JsonObject? = null,
        referer: String? = null,
        extraHeaders: Map<String, String> = emptyMap(),
    ): ApiResult = execute(account, method, url, body, referer, extraHeaders)

    // ---------------------------------------------------------------- 内部实现

    private fun baseUrl(account: Account): String = "${account.scheme}://${account.host}"

    fun baseUrl(edition: Edition): String = "${edition.scheme}://${edition.host}"

    fun buildUrl(base: String, path: String, query: Map<String, String>): String {
        val normalizedBase = base.trimEnd('/')
        val normalizedPath = when {
            path.isEmpty() -> ""
            path.startsWith("/") -> path
            else -> "/$path"
        }
        val queryString = query.entries
            .filter { it.key.isNotBlank() && it.value.isNotBlank() }
            .joinToString("&") { (k, v) -> "${k.encodeURLParameter()}=${v.encodeURLParameter()}" }
        if (queryString.isEmpty()) return "$normalizedBase$normalizedPath"
        val sep = when {
            !normalizedPath.contains('?') -> "?"
            normalizedPath.endsWith('?') || normalizedPath.endsWith('&') -> ""
            else -> "&"
        }
        return "$normalizedBase$normalizedPath$sep$queryString"
    }

    private suspend fun execute(
        account: Account?,
        method: String,
        url: String,
        body: JsonObject?,
        referer: String?,
        extraHeaders: Map<String, String>,
    ): ApiResult {
        val started = nowMillis()
        val response: HttpResponse = try {
            client.request(url) {
                this.method = HttpMethod.parse(method.uppercase())
                profile.userAgent.takeIf { it.isNotBlank() }?.let { setUniqueHeader(HttpHeaders.UserAgent, it) }
                profile.headers.forEach { (k, v) ->
                    if (!(body != null && k.equals(HttpHeaders.ContentType, ignoreCase = true))) {
                        setUniqueHeader(k, v)
                    }
                }
                if (account != null) applyAuth(this, account)
                referer?.takeIf { it.isNotBlank() }?.let { setUniqueHeader(HttpHeaders.Referrer, it) }
                extraHeaders.forEach { (k, v) ->
                    if (!(body != null && k.equals(HttpHeaders.ContentType, ignoreCase = true))) {
                        setUniqueHeader(k, v)
                    }
                }
                if (body != null) {
                    headers.remove(HttpHeaders.ContentType)
                    setBody(TextContent(body.toString(), ContentType.Application.Json.withCharset(Charsets.UTF_8)))
                }
            }
        } catch (ce: CancellationException) {
            throw ce
        } catch (t: Throwable) {
            return ApiResult(
                httpStatus = -1,
                body = t.message ?: t::class.simpleName ?: "network error",
                elapsedMs = nowMillis() - started,
                ok = false,
            )
        }

        val text = try {
            response.bodyAsText()
        } catch (ce: CancellationException) {
            throw ce
        } catch (_: Throwable) {
            ""
        }

        val parsed = runCatching { json.parseToJsonElement(text).jsonObject }.getOrNull()
        val code = parsed?.let { obj ->
            profile.result.allCodeKeys().firstNotNullOfOrNull { key -> obj[key].asNonNullIntOrNull() }
        }
        val message = parsed?.let { obj ->
            profile.result.allMessageKeys().firstNotNullOfOrNull { key ->
                obj[key].asNonNullStringOrNull()?.takeIf { it.isNotBlank() }
            }
        }
        val httpStatus = response.status.value
        val auth = if (httpStatus in 200..399) extractAuth(response, account) else null
        val businessOk = (httpStatus in 200..299) && profile.result.isOkCode(code)

        return ApiResult(
            httpStatus = httpStatus,
            body = text,
            json = parsed,
            code = code,
            message = message,
            elapsedMs = nowMillis() - started,
            auth = auth,
            ok = businessOk,
        )
    }

    private fun HttpRequestBuilder.setUniqueHeader(name: String, value: String) {
        headers.remove(name)
        headers.append(name, value)
    }

    private fun applyAuth(builder: HttpRequestBuilder, account: Account) {
        val rawBearer = account.bearer?.takeIf { it.isNotBlank() }
        if (rawBearer != null) {
            val bareToken = stripBearerPrefix(rawBearer)
            if (bareToken.isNotBlank()) {
                builder.setUniqueHeader(profile.auth.bearerHeader, profile.auth.bearerPrefix + bareToken)
            }
        }
        val sessionCookieName = profile.auth.primarySessionCookie()
        val csrfCookieName = profile.auth.effectiveCsrfCookie()
        val cookies = buildList {
            account.sessionId?.takeIf { it.isNotBlank() }?.let { add("$sessionCookieName=$it") }
            account.csrfToken?.takeIf { it.isNotBlank() }?.let { add("$csrfCookieName=$it") }
        }
        if (cookies.isNotEmpty()) {
            builder.setUniqueHeader(HttpHeaders.Cookie, cookies.joinToString("; "))
        }
        account.csrfToken?.takeIf { it.isNotBlank() }?.let {
            builder.setUniqueHeader(profile.auth.csrfHeader, it)
        }
    }

    private fun extractAuth(response: HttpResponse, account: Account?): AuthUpdate? {
        // 按配置顺序取第一个非空响应头（确保 set-auth 优先于 authorization）
        val bearer = profile.auth.tokenResponseHeaders.firstNotNullOfOrNull { name ->
            response.headers.getAll(name)
                ?.firstOrNull { it.isNotBlank() }
                ?.let { stripBearerPrefix(it) }
                ?.takeIf { it.isNotBlank() }
        }

        var sessionId: String? = null
        var csrf: String? = null
        val csrfCookieName = profile.auth.effectiveCsrfCookie()
        val sessionCookieNames = profile.auth.acceptedSessionCookies()

        val setCookies = response.headers.getAll(HttpHeaders.SetCookie).orEmpty()
        setCookies.forEach { raw ->
            val segments = raw.split(';')
            val pair = segments.firstOrNull()?.trim().orEmpty()
            val idx = pair.indexOf('=')
            if (idx <= 0) return@forEach
            val name = pair.substring(0, idx).trim()
            val value = pair.substring(idx + 1).trim().trim('"')
            if (value.isEmpty() || value.equals("deleted", ignoreCase = true)) return@forEach

            // 忽略 Max-Age<=0 或明确过期的清 Cookie 响应头
            val isDeletion = segments.drop(1).any { attr ->
                val trimmed = attr.trim()
                val eq = trimmed.indexOf('=')
                if (eq <= 0) return@any false
                val attrName = trimmed.substring(0, eq).trim().lowercase()
                val attrVal = trimmed.substring(eq + 1).trim()
                when (attrName) {
                    "max-age" -> (attrVal.toLongOrNull() ?: 1L) <= 0L
                    "expires" -> attrVal.contains("1970") || attrVal.contains("1969")
                    else -> false
                }
            }
            if (isDeletion) return@forEach

            when {
                name.equals(csrfCookieName, ignoreCase = true) -> csrf = value
                sessionCookieNames.any { it.equals(name, ignoreCase = true) } -> sessionId = value
            }
        }

        // 只在确实产生非空变更时返回，避免无意义地反复写存储
        val effectiveBearer = bearer?.takeIf { it != account?.bearer }
        val effectiveSession = sessionId?.takeIf { it != account?.sessionId }
        val effectiveCsrf = csrf?.takeIf { it != account?.csrfToken }
        return if (effectiveBearer != null || effectiveSession != null || effectiveCsrf != null) {
            AuthUpdate(effectiveBearer, effectiveSession, effectiveCsrf)
        } else {
            null
        }
    }

    private fun stripBearerPrefix(raw: String): String {
        val trimmed = raw.trim()
        val prefix = profile.auth.bearerPrefix
        if (prefix.isNotEmpty() && trimmed.startsWith(prefix, ignoreCase = true)) {
            return trimmed.substring(prefix.length).trim()
        }
        val trimmedPrefix = prefix.trim()
        if (trimmedPrefix.isNotEmpty() && trimmed.startsWith("$trimmedPrefix ", ignoreCase = true)) {
            return trimmed.substring(trimmedPrefix.length + 1).trim()
        }
        return trimmed
    }
}
