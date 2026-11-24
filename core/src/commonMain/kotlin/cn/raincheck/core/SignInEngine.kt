package cn.raincheck.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** 一次签到所需的课堂上下文。 */
data class LessonContext(
    val lessonId: String,
    val classroomId: String? = null,
    val name: String? = null,
) {
    fun display(): String = buildString {
        name?.takeIf { it.isNotBlank() }?.let { append(it) } ?: append(lessonId)
        classroomId?.let { append(" / 课堂 ").append(it) }
    }
}

/**
 * 多账号签到引擎。
 *
 * 关键设计：
 *  - **策略链**：动态码 / 静态码 / 网页兜底 / 同源白名单 URL 依次尝试，命中即停；
 *  - **同源安全护栏**：`QR_URL_POST`/`QR_URL_GET` 严格校验 scheme 与域名白名单，绝不向第三方外发凭据；
 *  - **账号并发**：账号之间并发、账号内部串行，避免同账号触发风控；
 *  - **策略级重试**：只对网络错误与可重试 5xx/429 退避，遇到过期/鉴权关键字即使 5xx 也立即中止；
 *  - **会话回填**：响应带新 `set-auth` / Set-Cookie 立即更新 `current` 供后续重试与策略使用，并串行通知账号池；
 *  - **严格演练**：`dryRun == true` 跳过 `discover()` 与所有网络调用，产出 [SignState.DRY_RUN]。
 */
class SignInEngine(
    private val api: RainCheckApi,
    private val profile: ProtocolProfile,
    private val onAccountUpdated: (Account) -> Unit = {},
    private val log: (String) -> Unit = {},
) {
    private val updateMutex = Mutex()

    /** 从服务端推断当前进行中的课堂（找不到或失败返回 null）。 */
    suspend fun discover(account: Account, ticket: QrTicket? = null): LessonContext? {
        val ref = AccountRef(account)
        return when (val outcome = discoverDetailed(ref, ticket)) {
            is DiscoverOutcome.Found -> outcome.context
            else -> null
        }
    }

    fun strategiesFor(ticket: QrTicket): List<StrategySpec> {
        val ordered = profile.orderedStrategies(ticket.kind)
        return ordered.filter { spec ->
            spec.requires.all { key ->
                when (key) {
                    "lessonId" -> true // lessonId 可在运行期由 discover 注入
                    "c" -> !ticket.dynamicCode.isNullOrBlank()
                    "t" -> !ticket.timestamp.isNullOrBlank()
                    "s" -> !ticket.signature.isNullOrBlank()
                    else -> !ticket.params[key].isNullOrBlank()
                }
            }
        }.filter { spec ->
            if (isQrUrlStrategy(spec.id)) !ticket.url.isNullOrBlank() else spec.endpoint != null
        }
    }

    /** 单账号签到。 */
    suspend fun signIn(account: Account, ticket: QrTicket, options: SignOptions = SignOptions()): SignResult {
        val attempts = mutableListOf<StrategyAttempt>()
        val currentRef = AccountRef(account)

        if (!account.hasCredential) {
            return SignResult(
                accountId = account.id,
                label = account.label,
                state = SignState.AUTH_REQUIRED,
                message = "账号没有配置 token / sessionid",
            )
        }

        if (ticket.kind == TicketKind.LOGIN) {
            return SignResult(
                accountId = account.id,
                label = account.label,
                state = SignState.NO_CONTEXT,
                message = "这是登录二维码，请先在账号页扫码登录",
            )
        }

        val allCandidates = strategiesFor(ticket).let { list ->
            val wanted = options.strategyIds?.filter { it.isNotBlank() }?.takeIf { it.isNotEmpty() }
            if (wanted == null) list else list.filter { wanted.contains(it.id) }
        }
        if (allCandidates.isEmpty()) {
            return SignResult(
                accountId = account.id,
                label = account.label,
                state = SignState.NO_CONTEXT,
                message = "profile 没有适用于 ${ticket.kind} 的策略",
                lessonId = ticket.lessonId,
            )
        }

        // 演练模式：绝对不发起任何网络请求（包括跳过 discover()！）
        if (options.dryRun) {
            val dryContext = LessonContext(
                lessonId = ticket.lessonId ?: "<discover>",
                classroomId = ticket.classroomId,
            )
            for (spec in allCandidates) {
                val variables = buildVars(currentRef.account, dryContext, ticket, spec)
                attempts += simulateDryRun(currentRef.account, spec, variables, dryContext, ticket)
            }
            return SignResult(
                accountId = currentRef.account.id,
                label = currentRef.account.label,
                state = SignState.DRY_RUN,
                message = "演练模式：已模拟 ${attempts.size} 条策略，未发起网络请求",
                strategy = allCandidates.firstOrNull()?.id,
                lessonId = ticket.lessonId,
                attempts = attempts,
            )
        }

        // 解析课堂上下文；无 lessonId 时调用 discover() 且绝不吞掉 401/403 与网络异常
        var discoverFailure: DiscoverOutcome? = null
        val context: LessonContext? = when {
            ticket.lessonId != null -> LessonContext(ticket.lessonId, ticket.classroomId)
            else -> when (val outcome = discoverDetailed(currentRef, ticket)) {
                is DiscoverOutcome.Found -> outcome.context
                is DiscoverOutcome.AuthRequired -> {
                    return SignResult(
                        accountId = currentRef.account.id,
                        label = currentRef.account.label,
                        state = SignState.AUTH_REQUIRED,
                        message = outcome.message,
                        attempts = listOf(outcome.attempt),
                    )
                }
                is DiscoverOutcome.NetworkError, is DiscoverOutcome.NotFound -> {
                    discoverFailure = outcome
                    null
                }
            }
        }

        // 当缺少 lessonId 时，仅保留不依赖 lessonId 且合法同源的策略（如白名单 QR_URL_*），避免误拦截
        val candidates = if (context != null) {
            allCandidates
        } else {
            allCandidates.filter { spec ->
                !spec.requires.contains("lessonId") &&
                    (!isQrUrlStrategy(spec.id) || (ticket.url != null && profile.isAllowedQrUrl(ticket.url, currentRef.account)))
            }
        }

        if (candidates.isEmpty()) {
            return when (val fail = discoverFailure) {
                is DiscoverOutcome.NetworkError -> SignResult(
                    accountId = currentRef.account.id,
                    label = currentRef.account.label,
                    state = SignState.ERROR,
                    message = fail.message,
                    attempts = listOf(fail.attempt),
                )
                is DiscoverOutcome.NotFound -> SignResult(
                    accountId = currentRef.account.id,
                    label = currentRef.account.label,
                    state = SignState.NO_CONTEXT,
                    message = fail.message,
                    attempts = listOfNotNull(fail.attempt),
                )
                else -> SignResult(
                    accountId = currentRef.account.id,
                    label = currentRef.account.label,
                    state = SignState.NO_CONTEXT,
                    message = "无法确定 lessonId，请确认二维码属于进行中的课堂",
                )
            }
        }

        var lastMessage = "所有策略均被拒绝"
        for (spec in candidates) {
            val variables = buildVars(currentRef.account, context, ticket, spec)
            val strategyAttempts = runStrategy(currentRef, spec, variables, context, ticket, options)
            attempts += strategyAttempts
            val finalAttempt = strategyAttempts.lastOrNull() ?: continue

            val classified = classify(finalAttempt)
            if (classified == SignState.SUCCESS || classified == SignState.ALREADY) {
                val defaultMsg = if (classified == SignState.ALREADY) "已签到" else "签到成功"
                return SignResult(
                    accountId = currentRef.account.id,
                    label = currentRef.account.label,
                    state = classified,
                    message = finalAttempt.message?.takeIf { it.isNotBlank() } ?: defaultMsg,
                    strategy = spec.id,
                    lessonId = context?.lessonId,
                    attempts = attempts,
                )
            }

            lastMessage = finalAttempt.message?.takeIf { it.isNotBlank() } ?: lastMessage
            if (classified == SignState.AUTH_REQUIRED) {
                return SignResult(
                    accountId = currentRef.account.id,
                    label = currentRef.account.label,
                    state = SignState.AUTH_REQUIRED,
                    message = lastMessage,
                    strategy = spec.id,
                    lessonId = context?.lessonId,
                    attempts = attempts,
                )
            }
            if (classified == SignState.TICKET_EXPIRED && options.stopWhenTicketExpired) {
                return SignResult(
                    accountId = currentRef.account.id,
                    label = currentRef.account.label,
                    state = SignState.TICKET_EXPIRED,
                    message = lastMessage,
                    strategy = spec.id,
                    lessonId = context?.lessonId,
                    attempts = attempts,
                )
            }
            log("${currentRef.account.label}: ${spec.id} 未通过 - $lastMessage")
        }

        val networkAttempts = attempts.filter { it.httpStatus != null }
        val finalState = when {
            networkAttempts.isNotEmpty() && networkAttempts.all { classify(it) == SignState.ERROR } -> SignState.ERROR
            else -> attempts.lastOrNull()?.let { classify(it) } ?: SignState.FAILED
        }
        val safeFinalState = if (finalState == SignState.SUCCESS || finalState == SignState.ALREADY) {
            SignState.FAILED
        } else {
            finalState
        }

        return SignResult(
            accountId = currentRef.account.id,
            label = currentRef.account.label,
            state = safeFinalState,
            message = lastMessage,
            strategy = attempts.lastOrNull()?.strategy,
            lessonId = context?.lessonId,
            attempts = attempts,
        )
    }

    /** 多账号并发签到。 */
    suspend fun signInAll(
        accounts: List<Account>,
        ticket: QrTicket,
        options: SignOptions = SignOptions(),
    ): SignBatchReport {
        val started = nowMillis()
        val targets = accounts.filter { it.enabled }
        if (targets.isEmpty()) {
            return SignBatchReport(emptyList(), started, nowMillis(), ticket)
        }
        val semaphore = Semaphore(options.concurrency)
        val results = coroutineScope {
            targets.mapIndexed { index, account ->
                async {
                    if (options.staggerMs > 0 && index > 0) delay(index * options.staggerMs)
                    semaphore.withPermit {
                        try {
                            signIn(account, ticket, options)
                        } catch (ce: CancellationException) {
                            throw ce
                        } catch (error: Throwable) {
                            SignResult(
                                accountId = account.id,
                                label = account.label,
                                state = SignState.ERROR,
                                message = error.message ?: error::class.simpleName ?: "未知错误",
                            )
                        }
                    }
                }
            }.awaitAll()
        }
        return SignBatchReport(results, started, nowMillis(), ticket)
    }

    // ---------------------------------------------------------------- 上下文发现

    private suspend fun discoverDetailed(currentRef: AccountRef, ticket: QrTicket?): DiscoverOutcome {
        val active = api.call(currentRef.account, "activeLesson")
        applyAuthUpdateIfChanged(currentRef, active.auth, markOk = active.ok)

        val endpointPath = runCatching { profile.endpoint("activeLesson").path }.getOrDefault("/api/v3/classroom/on-lesson-upcoming-exam")
        val attempt = StrategyAttempt(
            strategy = "DISCOVER_ACTIVE_LESSON",
            httpStatus = active.httpStatus,
            code = active.code,
            message = active.message ?: active.body.take(160),
            ok = active.ok,
            requestLine = "GET ${currentRef.account.scheme}://${currentRef.account.host}$endpointPath",
            responseBody = active.body.take(2000),
            elapsedMs = active.elapsedMs,
        )

        if (active.httpStatus == -1) {
            return DiscoverOutcome.NetworkError(
                message = "查询进行中课堂网络异常: ${active.body.take(120)}",
                attempt = attempt,
            )
        }
        if (active.httpStatus == 401 || active.httpStatus == 403) {
            return DiscoverOutcome.AuthRequired(
                message = active.message?.takeIf { it.isNotBlank() } ?: "查询课堂时鉴权失败 (HTTP ${active.httpStatus})",
                attempt = attempt,
            )
        }
        val rawMsg = active.message?.takeIf { it.isNotBlank() } ?: active.body
        if (!active.ok && matchesAnyKeyword(rawMsg, profile.result.authKeywords)) {
            return DiscoverOutcome.AuthRequired(
                message = active.message?.takeIf { it.isNotBlank() } ?: "查询课堂时会话失效",
                attempt = attempt,
            )
        }
        if (!active.ok && (active.httpStatus >= 500 || profile.result.retryHttpStatus.contains(active.httpStatus))) {
            return DiscoverOutcome.NetworkError(
                message = active.message?.takeIf { it.isNotBlank() } ?: "查询进行中课堂服务端异常 (HTTP ${active.httpStatus})",
                attempt = attempt,
            )
        }

        if (active.ok) {
            val data = active.data()
            val lessons = data?.let { findLessonObjects(it) }.orEmpty()
            val matched = when {
                ticket?.classroomId != null ->
                    lessons.firstOrNull { it.classroomId == ticket.classroomId } ?: lessons.firstOrNull()
                else -> lessons.firstOrNull()
            }
            if (matched != null) return DiscoverOutcome.Found(matched)
        }

        return DiscoverOutcome.NotFound(
            message = "无法确定 lessonId，请确认二维码属于进行中的课堂",
            attempt = attempt,
        )
    }

    // ---------------------------------------------------------------- 单策略执行

    private fun buildRequestPlan(
        account: Account,
        spec: StrategySpec,
        vars: Map<String, JsonElement>,
        ticket: QrTicket,
    ): PlanBuildResult {
        val base = "${account.scheme}://${account.host}"
        if (isQrUrlStrategy(spec.id)) {
            val url = ticket.url
                ?: return PlanBuildResult.Rejected("二维码不是 URL，跳过")
            val securityError = profile.validateQrUrl(url, account)
            if (securityError != null) {
                return PlanBuildResult.Rejected("安全拦截：拒绝向非白名单地址发送凭据（$securityError）")
            }
            val method = if (spec.id == "QR_URL_GET") "GET" else "POST"
            return PlanBuildResult.Ready(RequestPlan(method, url, if (method == "GET") null else qrBody(ticket)))
        }
        val endpoint = spec.endpoint?.let { profile.endpoint(it) }
            ?: return PlanBuildResult.Rejected("profile 缺少 endpoint")
        val path = Template.renderPath(endpoint.path, vars)
        val url = api.buildUrl(base, path, Template.renderMap(endpoint.query, vars))
        val body = endpoint.body?.let { Template.renderBody(it, vars) }
        return PlanBuildResult.Ready(RequestPlan(endpoint.method, url, body))
    }

    private fun simulateDryRun(
        account: Account,
        spec: StrategySpec,
        vars: Map<String, JsonElement>,
        context: LessonContext,
        ticket: QrTicket,
    ): StrategyAttempt {
        return when (val built = buildRequestPlan(account, spec, vars, ticket)) {
            is PlanBuildResult.Rejected -> StrategyAttempt(
                strategy = spec.id,
                ok = false,
                message = built.reason,
            )
            is PlanBuildResult.Ready -> StrategyAttempt(
                strategy = spec.id,
                ok = false,
                message = "演练模式，未发送",
                requestLine = "${built.plan.method} ${built.plan.url}",
                requestBody = built.plan.body?.toString(),
            )
        }
    }

    private suspend fun runStrategy(
        currentRef: AccountRef,
        spec: StrategySpec,
        vars: Map<String, JsonElement>,
        context: LessonContext?,
        ticket: QrTicket,
        options: SignOptions,
    ): List<StrategyAttempt> {
        val plan = when (val built = buildRequestPlan(currentRef.account, spec, vars, ticket)) {
            is PlanBuildResult.Rejected -> return listOf(
                StrategyAttempt(
                    strategy = spec.id,
                    ok = false,
                    message = built.reason,
                ),
            )
            is PlanBuildResult.Ready -> built.plan
        }

        val recorded = mutableListOf<StrategyAttempt>()
        var attemptIndex = 0
        while (attemptIndex < options.maxAttemptsPerStrategy) {
            val activeAccount = currentRef.account
            val base = "${activeAccount.scheme}://${activeAccount.host}"
            val referer = context?.classroomId?.let { "$base/v2/web/studentLog/$it" } ?: "$base/v2/web/index"

            val result = api.raw(
                account = activeAccount,
                method = plan.method,
                url = plan.url,
                body = plan.body,
                referer = referer,
            )

            val rawAttempt = StrategyAttempt(
                strategy = spec.id,
                httpStatus = result.httpStatus,
                code = result.code,
                message = result.message ?: result.body.take(160),
                ok = false,
                requestLine = "${plan.method} ${plan.url}",
                requestBody = plan.body?.toString(),
                responseBody = result.body.take(2000),
                elapsedMs = result.elapsedMs,
            )
            val state = classify(rawAttempt)
            val isOk = state == SignState.SUCCESS || state == SignState.ALREADY
            val attempt = rawAttempt.copy(ok = isOk)
            recorded += attempt

            // 立即回填新凭据到 currentRef，后续重试与后续策略立刻使用新会话
            applyAuthUpdateIfChanged(currentRef, result.auth, markOk = isOk)

            val retryableStatus = result.httpStatus == -1 || profile.result.retryHttpStatus.contains(result.httpStatus)
            val abortImmediately = state == SignState.TICKET_EXPIRED || state == SignState.AUTH_REQUIRED
            if (isOk || abortImmediately || !retryableStatus || attemptIndex >= options.maxAttemptsPerStrategy - 1) {
                break
            }

            attemptIndex++
            val shift = (attemptIndex - 1).coerceIn(0, 10)
            val backoffMs = (options.baseBackoffMs * (1L shl shift)).coerceAtMost(30_000L)
            if (backoffMs > 0) delay(backoffMs)
        }
        return recorded
    }

    private suspend fun applyAuthUpdateIfChanged(
        currentRef: AccountRef,
        auth: AuthUpdate?,
        markOk: Boolean,
    ) {
        if (auth == null || auth.isEmpty) return
        val before = currentRef.account
        val updated = auth.applyTo(before, markOk = markOk)
        val credentialChanged = updated.bearer != before.bearer ||
            updated.sessionId != before.sessionId ||
            updated.csrfToken != before.csrfToken
        if (credentialChanged) {
            currentRef.account = updated
            updateMutex.withLock {
                onAccountUpdated(updated)
            }
        }
    }

    private fun qrBody(ticket: QrTicket): JsonObject = JsonObject(
        buildMap {
            ticket.params.forEach { (k, v) -> put(k, JsonPrimitive(v)) }
        },
    )

    private fun buildVars(
        account: Account,
        context: LessonContext?,
        ticket: QrTicket,
        spec: StrategySpec,
    ): Map<String, JsonElement> = buildMap {
        context?.lessonId?.let { put("lessonId", JsonPrimitive(it)) }
        context?.classroomId?.let { put("classroomId", JsonPrimitive(it)) }
        ticket.checkinId?.let { put("checkinId", JsonPrimitive(it)) }
        ticket.params.forEach { (k, v) -> put(k, JsonPrimitive(v)) }
        account.userId?.let { put("userId", JsonPrimitive(it)) }
        spec.vars.forEach { (k, v) -> put(k, v) }
    }

    /**
     * 统一状态分类器（严格优先级）：
     *  1. 网络异常 (`httpStatus == -1`) -> [SignState.ERROR]（绝不误判为 AUTH_REQUIRED）
     *  2. HTTP 401/403 -> [SignState.AUTH_REQUIRED]（优先于 alreadyKeywords）
     *  3. 非 401/403/5xx 响应命中 `alreadyKeywords` -> [SignState.ALREADY]（优先于 `okCodes`！）
     *  4. HTTP 2xx 且 `code in okCodes` -> [SignState.SUCCESS]
     *  5. 命中 `authKeywords`（大小写不敏感，含 HTTP 200 业务鉴权失败）-> [SignState.AUTH_REQUIRED]
     *  6. 命中 `expiredKeywords`（大小写不敏感）-> [SignState.TICKET_EXPIRED]
     *  7. 可重试状态码 / 5xx -> [SignState.ERROR]
     *  8. 其他 -> [SignState.FAILED]
     */
    internal fun classify(attempt: StrategyAttempt): SignState {
        val status = attempt.httpStatus
        if (status == -1) return SignState.ERROR
        if (status == 401 || status == 403) return SignState.AUTH_REQUIRED

        val text = attempt.message?.takeIf { it.isNotBlank() } ?: attempt.responseBody.orEmpty()
        val isServerOrRetryableError = status != null &&
            (status >= 500 || profile.result.retryHttpStatus.contains(status))

        if (status != null && !isServerOrRetryableError && matchesAnyKeyword(text, profile.result.alreadyKeywords)) {
            return SignState.ALREADY
        }
        if (status != null && status in 200..299 && profile.result.isOkCode(attempt.code)) {
            return SignState.SUCCESS
        }
        if (matchesAnyKeyword(text, profile.result.authKeywords)) {
            return SignState.AUTH_REQUIRED
        }
        if (matchesAnyKeyword(text, profile.result.expiredKeywords)) {
            return SignState.TICKET_EXPIRED
        }
        if (isServerOrRetryableError) {
            return SignState.ERROR
        }
        return SignState.FAILED
    }

    private fun matchesAnyKeyword(text: String, keywords: List<String>): Boolean {
        if (text.isBlank()) return false
        return keywords.any { kw -> kw.isNotBlank() && text.contains(kw, ignoreCase = true) }
    }

    private fun isQrUrlStrategy(id: String): Boolean =
        id == "QR_URL_POST" || id == "QR_URL_GET"

    // ---------------------------------------------------------------- 解析辅助

    private fun findLessonObjects(data: JsonObject): List<LessonContext> {
        val arrays = listOf("onLessonClassrooms", "classrooms", "lessonList", "lessons")
        for (key in arrays) {
            val array = data[key] as? JsonArray ?: continue
            val parsed = array.mapNotNull { element ->
                val obj = element as? JsonObject ?: return@mapNotNull null
                val lessonId = obj.firstNonBlankString("lessonId", "lesson_id", "id", "courseId")
                if (lessonId.isNullOrBlank()) return@mapNotNull null
                LessonContext(
                    lessonId = lessonId,
                    classroomId = obj.firstNonBlankString("classroomId", "classroom_id"),
                    name = obj.firstNonBlankString("courseName", "lessonName", "name", "title"),
                )
            }
            if (parsed.isNotEmpty()) return parsed
        }
        return emptyList()
    }

    private class AccountRef(var account: Account)

    private data class RequestPlan(val method: String, val url: String, val body: JsonObject?)

    private sealed class PlanBuildResult {
        data class Ready(val plan: RequestPlan) : PlanBuildResult()
        data class Rejected(val reason: String) : PlanBuildResult()
    }

    private sealed class DiscoverOutcome {
        data class Found(val context: LessonContext) : DiscoverOutcome()
        data class AuthRequired(val message: String, val attempt: StrategyAttempt) : DiscoverOutcome()
        data class NetworkError(val message: String, val attempt: StrategyAttempt) : DiscoverOutcome()
        data class NotFound(val message: String, val attempt: StrategyAttempt?) : DiscoverOutcome()
    }
}
