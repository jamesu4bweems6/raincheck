package cn.raincheck.core

/** 签到结果状态。 */
enum class SignState {
    /** 本次提交成功。 */
    SUCCESS,

    /** 服务端返回已签到/重复签到，按成功处理。 */
    ALREADY,

    /** 演练模式：仅模拟策略轨迹，未发起任何网络请求。 */
    DRY_RUN,

    /** 所有策略都被服务端拒绝。 */
    FAILED,

    /** 该账号会话失效，需要重新扫码登录。 */
    AUTH_REQUIRED,

    /** 二维码已过期（动态码刷新或被老师结束）。 */
    TICKET_EXPIRED,

    /** 缺 lessonId 且无法从服务端推断。 */
    NO_CONTEXT,

    /** 网络错误 / 5xx 或 429 重试耗尽。 */
    ERROR,
}

/** 单次策略尝试的原始轨迹，用于「报文实验室」展示。 */
data class StrategyAttempt(
    val strategy: String,
    val httpStatus: Int? = null,
    val code: Int? = null,
    val message: String? = null,
    val ok: Boolean = false,
    val requestLine: String = "",
    val requestBody: String? = null,
    val responseBody: String? = null,
    val elapsedMs: Long = 0L,
)

data class SignResult(
    val accountId: String,
    val label: String,
    val state: SignState,
    val message: String,
    val strategy: String? = null,
    val lessonId: String? = null,
    val attempts: List<StrategyAttempt> = emptyList(),
) {
    val ok: Boolean get() = state == SignState.SUCCESS || state == SignState.ALREADY
}

data class SignOptions(
    val concurrency: Int = 4,
    val maxAttemptsPerStrategy: Int = 3,
    val baseBackoffMs: Long = 800,
    val stopWhenTicketExpired: Boolean = true,
    /** 只模拟策略轨迹，绝对不发起任何网络请求（含跳过 discover）。 */
    val dryRun: Boolean = false,
    /** 指定策略链（默认用 profile 里的顺序）。 */
    val strategyIds: List<String>? = null,
    /** 账号之间错开的毫秒数，缓解同 IP 并发特征。 */
    val staggerMs: Long = 60,
) {
    init {
        require(concurrency in 1..32) { "并发数需要在 1..32" }
        require(maxAttemptsPerStrategy in 1..10) { "单策略尝试次数需要在 1..10" }
        require(baseBackoffMs in 0..30_000) { "基础退避时间需要在 0..30000 ms" }
        require(staggerMs in 0..10_000) { "错开延迟需要在 0..10000 ms" }
    }
}

/** 批量签到汇总。 */
data class SignBatchReport(
    val results: List<SignResult>,
    val startedAt: Long,
    val finishedAt: Long,
    val ticket: QrTicket,
) {
    val successCount: Int get() = results.count { it.ok }
    val dryRunCount: Int get() = results.count { it.state == SignState.DRY_RUN }
    val failedCount: Int get() = results.count { !it.ok && it.state != SignState.DRY_RUN }
    val elapsedMs: Long get() = (finishedAt - startedAt).coerceAtLeast(0L)
}

/** 登录轮询状态。 */
enum class LoginState { PENDING, SCANNED, NEED_CODE, AUTHORIZED, EXPIRED, ERROR }

data class LoginPoll(
    val state: LoginState,
    val message: String,
    val loginToken: String? = null,
    val qrContent: String? = null,
    val account: Account? = null,
)

/** 统一的服务端响应视图。 */
data class ApiResult(
    val httpStatus: Int,
    val body: String,
    val json: kotlinx.serialization.json.JsonObject? = null,
    val code: Int? = null,
    val message: String? = null,
    val elapsedMs: Long = 0L,
    val auth: AuthUpdate? = null,
    val ok: Boolean = (httpStatus in 200..299 && code == 0),
) {
    fun data(): kotlinx.serialization.json.JsonObject? =
        json?.get("data") as? kotlinx.serialization.json.JsonObject

    fun dataOf(key: String): kotlinx.serialization.json.JsonElement? = data()?.get(key)
}
