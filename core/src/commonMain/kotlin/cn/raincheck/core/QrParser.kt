package cn.raincheck.core

/**
 * 二维码解析器。
 *
 * 支持多种现实形态：
 *  1. 完整 URL（含 `https://`、`http://`、`app://yuketang` 等，支持端口、IPv6、自动剥离 `#fragment`）
 *  2. 无 scheme URL（如 `www.yuketang.cn/v2/web/studentLog/...`）
 *  3. 裸 query 串（`c=..&t=..&s=..&v=2`，网关截断或被转发后常见）
 *  4. 纯文本课堂号（全数字）
 */
object QrParser {

    fun parse(rawInput: String, profile: ProtocolProfile = ProtocolProfile()): QrTicket {
        val raw = rawInput.trim().trim('"', '\'', ' ')
        if (raw.isEmpty()) {
            return QrTicket(raw = raw, kind = TicketKind.UNKNOWN)
        }

        // 先剥离 URL #fragment，防止污染最后一个 query 参数值
        val clean = raw.substringBefore('#').trim()
        if (clean.isEmpty()) {
            return QrTicket(raw = raw, kind = TicketKind.UNKNOWN)
        }

        val spec = profile.qr
        val url: String? = resolveUrl(clean, spec, profile)

        // 若显式包含 "://" 但协议不在白名单 schemes 中，按非法/不支持输入返回 UNKNOWN
        if (url == null && clean.contains("://")) {
            return QrTicket(raw = raw, kind = TicketKind.UNKNOWN)
        }

        val query = when {
            url != null -> queryOf(url.substringAfter('?', ""))
            clean.contains('=') -> queryOf(clean.trimStart('?', '&'))
            else -> emptyMap()
        }

        val host = url?.let { extractHost(it) }
        val path = url?.let { extractPath(it) } ?: ""

        val lessonId = spec.lessonKeys.firstNotNullOfOrNull { query[it]?.takeIf { v -> v.isNotBlank() } }
        val classroomId = spec.classroomKeys.firstNotNullOfOrNull { query[it]?.takeIf { v -> v.isNotBlank() } }
        val checkinId = spec.checkinKeys.firstNotNullOfOrNull { query[it]?.takeIf { v -> v.isNotBlank() } }

        val dynamicKeys = spec.dynamicKeys.filter { it.isNotBlank() }
        val hasDynamic = dynamicKeys.isNotEmpty() && dynamicKeys.all { !query[it].isNullOrBlank() }
        val isDynamicQrPath = path.contains("dynamic-qr", ignoreCase = true)

        // 明确签到路径信号（含 check-in / checkin / dynamic-qr，绝不因路径含 qrcode/scan 误判为登录码）
        val isExplicitCheckinPath = isDynamicQrPath ||
            path.contains("check-in", ignoreCase = true) ||
            path.contains("checkin", ignoreCase = true)

        // 明确登录信号（匹配 path 或特定参数，绝不误匹配 host）
        val isExplicitLogin = path.contains("qrconnect", ignoreCase = true) ||
            path.contains("login", ignoreCase = true) ||
            path.contains("scan-handler", ignoreCase = true) ||
            query.containsKey("qrContent")

        // 宽泛登录路径提示（来自 profile.qr.loginPathHints，仅匹配 path 且优先级低于显式 lessonId 与签到路径）
        val isBroadLoginPath = !isExplicitCheckinPath && spec.loginPathHints.any { hint ->
            hint.isNotBlank() && path.contains(hint, ignoreCase = true)
        }

        val isPureDigits = clean.isNotEmpty() && clean.all { it.isDigit() }

        val kind = when {
            hasDynamic || isDynamicQrPath -> TicketKind.DYNAMIC_CHECKIN
            isExplicitLogin -> TicketKind.LOGIN
            lessonId != null || classroomId != null || isPureDigits -> TicketKind.LESSON_ONLY
            isBroadLoginPath -> TicketKind.LOGIN
            else -> TicketKind.UNKNOWN
        }

        val resolvedLesson = lessonId ?: if (kind == TicketKind.LESSON_ONLY && isPureDigits) clean else null

        return QrTicket(
            raw = raw,
            kind = kind,
            url = url,
            host = host,
            params = query,
            lessonId = resolvedLesson,
            classroomId = classroomId,
            checkinId = checkinId,
        )
    }

    /** 解析 `a=1&b=2`，值做完整 UTF-8 URL 解码；重复键保留第一个。 */
    fun queryOf(query: String): Map<String, String> {
        val cleaned = query.substringBefore('#')
        if (cleaned.isBlank()) return emptyMap()
        val out = LinkedHashMap<String, String>()
        cleaned.split('&').forEach { pair ->
            if (pair.isBlank()) return@forEach
            val idx = pair.indexOf('=')
            val key = if (idx >= 0) pair.substring(0, idx) else pair
            val value = if (idx >= 0) pair.substring(idx + 1) else ""
            val decodedKey = decode(key)
            if (decodedKey.isNotBlank() && !out.containsKey(decodedKey)) {
                out[decodedKey] = decode(value)
            }
        }
        return out
    }

    /** UTF-8 安全 URL 解码：正确保留多字节中文及代理对，不截断高位字节。 */
    internal fun decode(value: String): String {
        if (!value.contains('%') && !value.contains('+')) return value
        val bytes = ArrayList<Byte>(value.length)
        var i = 0
        while (i < value.length) {
            val c = value[i]
            when {
                c == '+' -> {
                    bytes.add(' '.code.toByte())
                    i++
                }
                c == '%' && i + 2 < value.length -> {
                    val v = value.substring(i + 1, i + 3).toIntOrNull(16)
                    if (v == null) {
                        bytes.add('%'.code.toByte())
                        i++
                    } else {
                        bytes.add(v.toByte())
                        i += 3
                    }
                }
                else -> {
                    val start = i
                    while (i < value.length && value[i] != '+' && value[i] != '%') {
                        i++
                    }
                    val utf8 = value.substring(start, i).encodeToByteArray()
                    for (b in utf8) bytes.add(b)
                }
            }
        }
        return bytes.toByteArray().decodeToString()
    }

    internal fun extractScheme(url: String): String? {
        val idx = url.indexOf("://")
        if (idx <= 0) return null
        val scheme = url.substring(0, idx)
        if (!scheme.all { it.isLetterOrDigit() || it == '+' || it == '-' || it == '.' }) return null
        return scheme.lowercase()
    }

    /** 提取主机名，保留显式端口号与 IPv6 方括号格式（统一小写）。 */
    internal fun extractHost(url: String): String? {
        val afterScheme = url.substringAfter("://", "")
        if (afterScheme.isEmpty()) return null
        val authority = afterScheme.substringBefore('/').substringBefore('?').substringBefore('#')
        val hostPort = authority.substringAfter('@').trim()
        if (hostPort.isEmpty()) return null

        if (hostPort.startsWith("[")) {
            val close = hostPort.indexOf(']')
            if (close <= 1) return null
            val rest = hostPort.substring(close + 1)
            if (rest.isNotEmpty()) {
                if (!rest.startsWith(":")) return null
                val port = rest.drop(1).toIntOrNull() ?: return null
                if (port !in 1..65535) return null
            }
            return hostPort.lowercase()
        }

        val colon = hostPort.indexOf(':')
        if (colon >= 0) {
            val hostPart = hostPort.substring(0, colon)
            val portPart = hostPort.substring(colon + 1)
            val port = portPart.toIntOrNull() ?: return null
            if (hostPart.isBlank() || port !in 1..65535) return null
            return "${hostPart.lowercase()}:$port"
        }
        return hostPort.lowercase()
    }

    internal fun extractPath(url: String): String {
        val afterScheme = url.substringAfter("://", "")
        if (afterScheme.isEmpty()) return ""
        val beforeQueryOrFrag = afterScheme.substringBefore('#').substringBefore('?')
        val slashIdx = beforeQueryOrFrag.indexOf('/')
        return if (slashIdx < 0) "/" else beforeQueryOrFrag.substring(slashIdx)
    }

    private fun resolveUrl(clean: String, spec: QrSpec, profile: ProtocolProfile): String? {
        val schemeIdx = clean.indexOf("://")
        if (schemeIdx > 0) {
            val scheme = clean.substring(0, schemeIdx)
            val allowed = spec.schemes.any { it.equals(scheme, ignoreCase = true) }
            return if (allowed) clean else null
        }
        // 支持无 scheme URL（如 www.yuketang.cn/v2/web/studentLog/... 或 127.0.0.1:8787/checkin?...）
        val sepIdx = clean.indexOfFirst { it == '/' || it == '?' }
        val head = if (sepIdx > 0) clean.substring(0, sepIdx) else clean
        if (head.isEmpty() || head.any { it == '=' || it == '&' || it.isWhitespace() }) return null

        val hasPathOrQuery = sepIdx > 0
        val looksLikeDomain = head.contains('.') && !head.startsWith('.') && !head.endsWith('.')
        val looksLikeLocalhost = head.equals("localhost", ignoreCase = true) ||
            head.startsWith("localhost:", ignoreCase = true)
        val looksLikeIpv6 = head.startsWith("[") && head.contains("]")
        val knownHost = profile.editionForHost(head) != null ||
            spec.allowedUrlHosts.any { it.equals(head, ignoreCase = true) }

        if ((hasPathOrQuery && (looksLikeDomain || looksLikeLocalhost || looksLikeIpv6)) || knownHost) {
            val inferredScheme = profile.editionForHost(head)?.scheme ?: "https"
            return "$inferredScheme://$clean"
        }
        return null
    }
}
