package cn.raincheck.core

import io.ktor.http.encodeURLPathPart
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.intOrNull

/**
 * 安全提取非 null 字符串：显式排除 [JsonNull] 与非 [JsonPrimitive]，
 * 杜绝 `JsonNull.content == "null"` 污染状态机与业务字段。
 */
fun JsonElement?.asNonNullStringOrNull(): String? {
    val primitive = this as? JsonPrimitive ?: return null
    if (primitive is JsonNull) return null
    return primitive.content
}

/** 安全提取非 null 整数：显式排除 [JsonNull] 与非 [JsonPrimitive]。 */
fun JsonElement?.asNonNullIntOrNull(): Int? {
    val primitive = this as? JsonPrimitive ?: return null
    if (primitive is JsonNull) return null
    return primitive.intOrNull ?: primitive.content.toIntOrNull()
}

/** 安全提取非 null 布尔值：显式排除 [JsonNull] 与非 [JsonPrimitive]。 */
fun JsonElement?.asNonNullBoolOrNull(): Boolean? {
    val primitive = this as? JsonPrimitive ?: return null
    if (primitive is JsonNull) return null
    return primitive.booleanOrNull
}

internal fun JsonObject.firstNonBlankString(vararg keys: String): String? =
    keys.firstNotNullOfOrNull { key ->
        this[key].asNonNullStringOrNull()?.takeIf { it.isNotBlank() }
    }

@Serializable
data class AuthSpec(
    val bearerHeader: String = "Authorization",
    val bearerPrefix: String = "Bearer ",
    val cookieNames: List<String> = listOf("sessionid", "csrftoken"),
    val csrfCookie: String = "csrftoken",
    val csrfHeader: String = "X-CSRFToken",
    val tokenResponseHeaders: List<String> = listOf("set-auth", "authorization"),
) {
    fun effectiveCsrfCookie(): String = csrfCookie.ifBlank { "csrftoken" }

    fun primarySessionCookie(): String {
        val csrf = effectiveCsrfCookie()
        return cookieNames.firstOrNull { !it.equals(csrf, ignoreCase = true) && it.isNotBlank() } ?: "sessionid"
    }

    fun acceptedSessionCookies(): List<String> {
        val csrf = effectiveCsrfCookie()
        val configured = cookieNames.filter { !it.equals(csrf, ignoreCase = true) && it.isNotBlank() }
        return (configured + listOf("sessionid", "sid")).distinctBy { it.lowercase() }
    }
}

@Serializable
data class EndpointSpec(
    val method: String,
    val path: String,
    val body: JsonObject? = null,
    val query: Map<String, String> = emptyMap(),
    val auth: Boolean = true,
    val note: String = "",
)

@Serializable
data class StrategySpec(
    val id: String,
    val endpoint: String? = null,
    val appliesTo: List<String> = emptyList(),
    val requires: List<String> = emptyList(),
    val vars: JsonObject = JsonObject(emptyMap()),
    val note: String = "",
)

@Serializable
data class QrSpec(
    val dynamicKeys: List<String> = listOf("c", "t", "s"),
    val lessonKeys: List<String> = listOf("lessonId", "lesson_id", "lessonid", "lid"),
    val classroomKeys: List<String> = listOf("classroomId", "classroom_id", "classroomid", "cid"),
    val checkinKeys: List<String> = listOf("checkinId", "checkin_id", "signId", "sign_id"),
    val loginPathHints: List<String> = listOf("login", "qrcode", "scan", "qrconnect"),
    val schemes: List<String> = listOf("https", "http", "app", "yuketang", "ykt", "rainclassroom"),
    val allowedUrlHosts: List<String> = emptyList(),
)

@Serializable
data class ResultSpec(
    val codeField: String = "code",
    val altCodeKeys: List<String> = listOf("errcode"),
    val okCodes: List<Int> = listOf(0),
    val messageFields: List<String> = listOf("msg", "message"),
    val altMessageKeys: List<String> = listOf("errmsg"),
    val alreadyKeywords: List<String> = listOf("已签到", "已经签到", "重复签到", "已参与"),
    val authKeywords: List<String> = listOf("登录", "未授权", "身份", "token", "会话", "unauthorized"),
    val expiredKeywords: List<String> = listOf("失效", "过期", "不存在", "二维码已"),
    val retryHttpStatus: List<Int> = listOf(408, 425, 429, 500, 502, 503, 504),
) {
    fun allCodeKeys(): List<String> =
        (listOf(codeField) + altCodeKeys).filter { it.isNotBlank() }.distinct()

    fun allMessageKeys(): List<String> =
        (messageFields + altMessageKeys).filter { it.isNotBlank() }.distinct()

    fun isOkCode(code: Int?): Boolean = code != null && okCodes.contains(code)
}

/**
 * 协议描述文件（`protocol/profile.json`）。
 *
 * 路径、请求体、策略顺序全部数据化，服务端改字段时改 JSON 即可，
 * Android / iOS / CLI 三端共用同一份配置，行为天然一致。
 */
@Serializable
data class ProtocolProfile(
    val version: Int = 1,
    val name: String = "yuketang",
    val updatedAt: String = "",
    val defaultEdition: String = "www",
    val editions: List<Edition> = emptyList(),
    val headers: Map<String, String> = emptyMap(),
    val userAgent: String = "",
    val auth: AuthSpec = AuthSpec(),
    val endpoints: Map<String, EndpointSpec> = emptyMap(),
    val strategies: List<StrategySpec> = emptyList(),
    @SerialName("qr") val qr: QrSpec = QrSpec(),
    @SerialName("result") val result: ResultSpec = ResultSpec(),
) {
    fun endpoint(name: String): EndpointSpec =
        endpoints[name] ?: throw ProtocolException("profile 缺少 endpoint: $name")

    fun edition(id: String): Edition? = editions.firstOrNull { it.id.equals(id, ignoreCase = true) }

    fun defaultEditionSpec(): Edition =
        edition(defaultEdition) ?: editions.firstOrNull() ?: Edition.WWW

    fun editionForHost(host: String): Edition? =
        editions.firstOrNull { it.host.equals(host, ignoreCase = true) }

    fun orderedStrategies(kind: TicketKind): List<StrategySpec> =
        strategies.filter { it.appliesTo.isEmpty() || it.appliesTo.contains(kind.name) }

    /**
     * 校验二维码中的直接请求 URL 是否属于同源或白名单域名与安全协议。
     *
     * 返回 `null` 表示放行；非空字符串为拦截原因。
     * 仅允许 `https`（或当前账号 / `profile.editions` 显式声明为 `http` 的主机）。
     */
    fun validateQrUrl(url: String, account: Account? = null): String? {
        val scheme = QrParser.extractScheme(url)?.lowercase()
            ?: return "URL 缺少合法协议"
        if (scheme != "https" && scheme != "http") {
            return "不允许的协议: $scheme"
        }
        val afterScheme = url.substringAfter("://", "")
        val authority = afterScheme.substringBefore('/').substringBefore('?').substringBefore('#')
        if (authority.isEmpty()) return "URL 缺少主机名"
        if (authority.contains('@') || authority.contains('\\') || authority.any { it.isWhitespace() }) {
            return "URL 主机段包含不安全字符"
        }
        val hostPort = QrParser.extractHost(url) ?: return "无法解析 URL 主机名"
        val normalized = normalizeHostPort(scheme, hostPort)

        val allowedHttps = mutableSetOf<String>()
        val allowedHttp = mutableSetOf<String>()

        editions.forEach { ed ->
            val edScheme = ed.scheme.lowercase()
            if (edScheme == "https") allowedHttps += normalizeHostPort("https", ed.host)
            if (edScheme == "http") allowedHttp += normalizeHostPort("http", ed.host)
        }
        qr.allowedUrlHosts.forEach { allowedHost ->
            if (allowedHost.isNotBlank()) {
                allowedHttps += normalizeHostPort("https", allowedHost)
            }
        }
        if (account != null && account.host.isNotBlank()) {
            val accScheme = account.scheme.lowercase()
            if (accScheme == "https") allowedHttps += normalizeHostPort("https", account.host)
            if (accScheme == "http") allowedHttp += normalizeHostPort("http", account.host)
        }

        return when (scheme) {
            "https" -> if (normalized in allowedHttps) null else "域名 $hostPort 不在白名单中"
            "http" -> if (normalized in allowedHttp) null else "拒绝向未显式允许的明文 HTTP 主机 $hostPort 发送凭据"
            else -> "不允许的协议: $scheme"
        }
    }

    fun isAllowedQrUrl(url: String, account: Account? = null): Boolean =
        validateQrUrl(url, account) == null

    private fun normalizeHostPort(scheme: String, rawHost: String): String {
        val lower = rawHost.trim().lowercase()
        return when {
            scheme == "https" && lower.endsWith(":443") -> lower.removeSuffix(":443")
            scheme == "http" && lower.endsWith(":80") -> lower.removeSuffix(":80")
            else -> lower
        }
    }

    companion object {
        private val json = Json {
            ignoreUnknownKeys = true
            isLenient = true
            explicitNulls = false
        }

        fun parse(text: String): ProtocolProfile = json.decodeFromString(serializer(), text)
    }
}

class ProtocolException(message: String) : IllegalStateException(message)

/** 模板渲染：`{lessonId}`、`{c}` 等占位符。整串就是一个占位符时保留原始 JSON 类型。 */
object Template {
    private val placeholder = Regex("\\{([A-Za-z0-9_]+)}")

    fun render(text: String, vars: Map<String, JsonElement>): String =
        placeholder.replace(text) { m ->
            val value = vars[m.groupValues[1]]
            when {
                value == null || value is JsonNull -> ""
                value is JsonPrimitive -> value.content
                else -> value.toString()
            }
        }

    /** 渲染 URL path 模板，对替换进来的动态路径段做 URL path 编码，防止 `/`、`?`、`#` 注入。 */
    fun renderPath(pathTemplate: String, vars: Map<String, JsonElement>): String =
        placeholder.replace(pathTemplate) { m ->
            val raw = vars[m.groupValues[1]].asNonNullStringOrNull().orEmpty()
            raw.encodeURLPathPart()
        }

    fun renderBody(body: JsonObject, vars: Map<String, JsonElement>): JsonObject =
        JsonObject(body.mapValues { (_, v) -> renderElement(v, vars) })

    fun renderElement(element: JsonElement, vars: Map<String, JsonElement>): JsonElement = when (element) {
        is JsonObject -> JsonObject(element.mapValues { (_, v) -> renderElement(v, vars) })
        is JsonArray -> JsonArray(element.map { renderElement(it, vars) })
        is JsonPrimitive -> {
            if (element is JsonNull || !element.isString) {
                element
            } else {
                val raw = element.content
                val single = placeholder.matchEntire(raw)
                if (single != null) {
                    val v = vars[single.groupValues[1]]
                    if (v == null || v is JsonNull) JsonPrimitive("") else v
                } else {
                    JsonPrimitive(render(raw, vars))
                }
            }
        }
    }

    fun renderMap(map: Map<String, String>, vars: Map<String, JsonElement>): Map<String, String> =
        map.mapValues { (_, v) -> render(v, vars) }

    fun varsOf(vararg pairs: Pair<String, Any?>): Map<String, JsonElement> =
        pairs.associate { (k, v) ->
            k to when (v) {
                null -> JsonPrimitive("")
                is JsonElement -> v
                is Int -> JsonPrimitive(v)
                is Long -> JsonPrimitive(v)
                is Double -> JsonPrimitive(v)
                is Float -> JsonPrimitive(v)
                is Number -> JsonPrimitive(v)
                is Boolean -> JsonPrimitive(v)
                else -> JsonPrimitive(v.toString())
            }
        }

    fun JsonElement.asStringOrNull(): String? = asNonNullStringOrNull()

    fun JsonElement.asIntOrNull(): Int? = asNonNullIntOrNull()

    fun JsonElement.asBoolOrNull(): Boolean? = asNonNullBoolOrNull()

    fun JsonObject.string(key: String): String? = this[key].asNonNullStringOrNull()
    fun JsonObject.int(key: String): Int? = this[key].asNonNullIntOrNull()
    fun JsonObject.obj(key: String): JsonObject? = this[key] as? JsonObject
}
