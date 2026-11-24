package cn.raincheck.core

import kotlinx.serialization.Serializable

/** 雨课堂校区/站点。host 不带 scheme，可带端口号。 */
@Serializable
data class Edition(
    val id: String,
    val label: String,
    val host: String,
    val scheme: String = "https",
) {
    val baseUrl: String get() = "$scheme://$host"

    companion object {
        val WWW = Edition("www", "雨课堂", "www.yuketang.cn")
        val PRO = Edition("pro", "雨课堂 Pro（荷塘/专业版）", "pro.yuketang.cn")
        val TSINGHUA = Edition("tsinghua", "荷塘雨课堂", "pro.yuketang.cn")
        val CHANGJIANG = Edition("changjiang", "长江雨课堂", "changjiang.yuketang.cn")
        val HUANGHE = Edition("huanghe", "黄河雨课堂", "huanghe.yuketang.cn")
        val XUETANGX = Edition("xuetangx", "学堂在线", "www.xuetangx.com")
        val MOCK = Edition("mock", "本地演练环境", "127.0.0.1:8787", "http")

        val presets: List<Edition> = listOf(WWW, PRO, TSINGHUA, CHANGJIANG, HUANGHE, XUETANGX, MOCK)

        fun fromHost(host: String, scheme: String? = null): Edition {
            val matched = presets.firstOrNull { it.host.equals(host, ignoreCase = true) }
            if (matched != null) {
                return if (scheme != null && !scheme.equals(matched.scheme, ignoreCase = true)) {
                    matched.copy(scheme = scheme.lowercase())
                } else {
                    matched
                }
            }
            return Edition(
                id = host,
                label = host,
                host = host,
                scheme = scheme?.lowercase() ?: "https",
            )
        }
    }
}

/**
 * 一个账号。
 *
 * 会话有两种独立载体，任选其一可用即可：
 *  - [bearer]：App / 桌面端 `Authorization: Bearer <token>`
 *  - [sessionId] + [csrfToken]：网页端 Cookie
 */
@Serializable
data class Account(
    val id: String,
    val label: String,
    val host: String = "www.yuketang.cn",
    val scheme: String = "https",
    val bearer: String? = null,
    val sessionId: String? = null,
    val csrfToken: String? = null,
    val enabled: Boolean = true,
    val createdAt: Long = 0L,
    val lastOkAt: Long? = null,
    val userId: String? = null,
    val note: String = "",
) {
    val edition: Edition get() = Edition(id = host, label = host, host = host, scheme = scheme)

    val hasCredential: Boolean
        get() = !bearer.isNullOrBlank() || !sessionId.isNullOrBlank()

    /** 返回脱敏后的凭据展示串；短凭据全量遮蔽，避免前缀泄露过多熵。 */
    fun maskedCredential(): String {
        val raw = bearer?.takeIf { it.isNotBlank() } ?: sessionId.orEmpty()
        if (raw.isEmpty()) return "未配置"
        return when {
            raw.length <= 12 -> "****"
            raw.length <= 20 -> raw.take(2) + "…" + raw.takeLast(2)
            else -> raw.take(4) + "…" + raw.takeLast(3)
        }
    }
}

/** 二维码类型。 */
enum class TicketKind {
    /** 老师端动态签到码：带 c/t/s 参数，几秒一轮换。 */
    DYNAMIC_CHECKIN,

    /** 静态签到码 / 课堂链接 / 课堂号：只带 lessonId。 */
    LESSON_ONLY,

    /** 登录二维码（pre-info 返回的 qrContent 或微信 qrconnect）。 */
    LOGIN,

    /** 无法识别的文本。 */
    UNKNOWN,
}

/** 解析后的二维码。 */
data class QrTicket(
    val raw: String,
    val kind: TicketKind,
    val url: String? = null,
    val host: String? = null,
    val params: Map<String, String> = emptyMap(),
    val lessonId: String? = null,
    val classroomId: String? = null,
    val checkinId: String? = null,
) {
    val dynamicCode: String? get() = params["c"]
    val timestamp: String? get() = params["t"]
    val signature: String? get() = params["s"]
    val version: String? get() = params["v"]

    /** 生成给 UI 看的一行摘要。 */
    fun summary(): String = when (kind) {
        TicketKind.DYNAMIC_CHECKIN -> "动态码 c=${dynamicCode.orEmpty().take(8)}… t=$timestamp"
        TicketKind.LESSON_ONLY -> "课堂 lessonId=${lessonId ?: "?"}"
        TicketKind.LOGIN -> "登录二维码"
        TicketKind.UNKNOWN -> "未识别: ${raw.take(40)}"
    }
}

/**
 * 账号存储抽象（Android 用 Keystore 加密存储、iOS 用 Keychain、CLI 用原子锁保护的 JSON 文件）。
 *
 * **线程安全契约**：[SignInEngine.signInAll] 可能在多协程环境下触发会话回填（尽管引擎内部已串行化
 * `onAccountUpdated`），UI 或 CLI 也可能并发读写；生产实现应保证 [load] / [save] / [upsert] / [remove]
 * 具备原子性与互斥保护，避免读-改-写丢更新或损坏落盘文件。
 */
interface AccountRepository {
    fun load(): List<Account>
    fun save(accounts: List<Account>)

    fun upsert(account: Account) {
        val list = load().toMutableList()
        val index = list.indexOfFirst { it.id == account.id }
        if (index >= 0) list[index] = account else list.add(account)
        save(list)
    }

    fun remove(id: String) {
        save(load().filterNot { it.id == id })
    }
}

/** 仅用于单测或纯内存演练的账号仓库。 */
class InMemoryAccountRepository(initial: List<Account> = emptyList()) : AccountRepository {
    private var accounts: List<Account> = initial.toList()
    override fun load(): List<Account> = accounts
    override fun save(accounts: List<Account>) {
        this.accounts = accounts.toList()
    }
}

/** 平台时间（毫秒），避免引入 kotlinx-datetime。 */
expect fun nowMillis(): Long

/** 生成账号 id。 */
expect fun randomId(): String
