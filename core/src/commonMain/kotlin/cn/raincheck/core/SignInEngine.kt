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

        val runAppScanFirst = shouldRunAppScan(ticket, options)
        val allCandidates = strategiesFor(ticket).let { list ->
            val wanted = options.strategyIds?.filter { it.isNotBlank() }?.takeIf { it.isNotEmpty() }
            if (wanted == null) list else list.filter { wanted.contains(it.id) }
        }
        if (allCandidates.isEmpty() && !runAppScanFirst) {
            return SignResult(
                accountId = account.id,
                label = account.label,
                state = SignState.NO_CONTEXT,
                message = "profile 没有适用于 ${ticket.kind} 的策略",
                lessonId = ticket.lessonId,
            )
        }

        // 演练模式：绝对不发起任何网络请求（包括跳过 appScan 与 discover()！）
        if (options.dryRun) {
            if (runAppScanFirst) {
                attempts += simulateAppScanDryRun(currentRef.account, ticket)
            }
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
                strategy = attempts.firstOrNull()?.strategy ?: allCandidates.firstOrNull()?.id,
                lessonId = ticket.lessonId,
                attempts = attempts,
            )
        }

        // 优先级 #1：官方 IPA 1.3.6 两步扫码签到（POST /api/v3/app/scan -> POST /api/v3/lesson/checkin source=21）
        // 在 discover() 之前直接执行，避免在 5–8s 动态二维码上浪费额外 RTT。
        var appScanContext: LessonContext? = null
        var bestFailure: Pair<StrategyAttempt, SignState>? = null
        if (runAppScanFirst) {
            when (val appScanOutcome = runAppScanCheckin(currentRef, ticket, options, attempts)) {
                is AppScanOutcome.Terminal -> return appScanOutcome.result
                is AppScanOutcome.Fallthrough -> {
                    appScanContext = appScanOutcome.discoveredContext
                    if (appScanOutcome.bestFailure != null) {
                        bestFailure = appScanOutcome.bestFailure
                    }
                }
            }
        }

        // 解析课堂上下文；无 lessonId 时优先复用 appScan 解析结果，再调用 discover() 且绝不吞掉 401/403 与网络异常
        var discoverFailure: DiscoverOutcome? = null
        val context: LessonContext? = when {
            ticket.lessonId != null -> LessonContext(ticket.lessonId, ticket.classroomId)
            appScanContext != null -> appScanContext
            allCandidates.isEmpty() -> null
            else -> when (val outcome = discoverDetailed(currentRef, ticket)) {
                is DiscoverOutcome.Found -> outcome.context
                is DiscoverOutcome.AuthRequired -> {
                    return SignResult(
                        accountId = currentRef.account.id,
                        label = currentRef.account.label,
                        state = SignState.AUTH_REQUIRED,
                        message = outcome.message,
                        attempts = attempts + outcome.attempt,
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
            if (allCandidates.isEmpty() && attempts.isNotEmpty()) {
                val chosen = bestFailure
                val lastAttempt = chosen?.first ?: attempts.last()
                val finalState = chosen?.second ?: classify(lastAttempt).let {
                    if (it == SignState.SUCCESS || it == SignState.ALREADY) SignState.FAILED else it
                }
                return SignResult(
                    accountId = currentRef.account.id,
                    label = currentRef.account.label,
                    state = finalState,
                    message = lastAttempt.message?.takeIf { it.isNotBlank() } ?: "APP_SCAN_CHECKIN 未通过",
                    strategy = lastAttempt.strategy,
                    lessonId = appScanContext?.lessonId ?: ticket.lessonId,
                    attempts = attempts,
                )
            }
            return when (val fail = discoverFailure) {
                is DiscoverOutcome.NetworkError -> SignResult(
                    accountId = currentRef.account.id,
                    label = currentRef.account.label,
                    state = SignState.ERROR,
                    message = fail.message,
                    attempts = attempts + fail.attempt,
                )
                is DiscoverOutcome.NotFound -> SignResult(
                    accountId = currentRef.account.id,
                    label = currentRef.account.label,
                    state = SignState.NO_CONTEXT,
                    message = bestFailure?.takeIf { it.second != SignState.AUTH_REQUIRED }
                        ?.first?.message?.takeIf { it.isNotBlank() } ?: fail.message,
                    attempts = attempts + listOfNotNull(fail.attempt),
                )
                else -> SignResult(
                    accountId = currentRef.account.id,
                    label = currentRef.account.label,
                    state = SignState.NO_CONTEXT,
                    message = bestFailure?.first?.message?.takeIf { it.isNotBlank() }
                        ?: "无法确定 lessonId，请确认二维码属于进行中的课堂",
                    attempts = attempts,
                )
            }
        }

        var lastMessage = bestFailure?.first?.message?.takeIf { it.isNotBlank() } ?: "所有策略均被拒绝"
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

            if (isMoreInformativeFailure(finalAttempt, bestFailure?.first)) {
                bestFailure = finalAttempt to classified
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
        val chosenFailure = bestFailure
        val finalState = when {
            networkAttempts.isNotEmpty() && networkAttempts.all { classify(it) == SignState.ERROR } -> SignState.ERROR
            chosenFailure != null -> chosenFailure.second
            else -> attempts.lastOrNull()?.let { classify(it) } ?: SignState.FAILED
        }
        val safeFinalState = if (finalState == SignState.SUCCESS || finalState == SignState.ALREADY) {
            SignState.FAILED
        } else {
            finalState
        }
        val finalMessage = chosenFailure?.first?.message?.takeIf { it.isNotBlank() } ?: lastMessage
        val finalStrategy = chosenFailure?.first?.strategy ?: attempts.lastOrNull()?.strategy

        return SignResult(
            accountId = currentRef.account.id,
            label = currentRef.account.label,
            state = safeFinalState,
            message = finalMessage,
            strategy = finalStrategy,
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
            val lessons = extractLessonsFromResponse(active)
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

    // ---------------------------------------------------------------- 官方两步扫码签到（IPA 1.3.6）

    private fun shouldRunAppScan(ticket: QrTicket, options: SignOptions): Boolean {
        if (!profile.endpoints.containsKey("appScan") || !profile.endpoints.containsKey("checkinAppScan")) {
            return false
        }
        if (ticket.kind == TicketKind.LOGIN || ticket.raw.isBlank()) return false
        val wanted = options.strategyIds?.filter { it.isNotBlank() }?.takeIf { it.isNotEmpty() }
        if (wanted != null) return wanted.contains(APP_SCAN_STRATEGY_ID)
        return ticket.url != null || ticket.kind == TicketKind.UNKNOWN
    }

    private fun simulateAppScanDryRun(account: Account, ticket: QrTicket): StrategyAttempt {
        val endpoint = profile.endpoint("appScan")
        val vars = Template.varsOf("qrRaw" to ticket.raw)
        val base = "${account.scheme}://${account.host}"
        val path = Template.renderPath(endpoint.path, vars)
        val url = api.buildUrl(base, path, Template.renderMap(endpoint.query, vars))
        val body = endpoint.body?.let { Template.renderBody(it, vars) }
        return StrategyAttempt(
            strategy = APP_SCAN_STRATEGY_ID,
            ok = false,
            message = "演练模式，未发送",
            requestLine = "${endpoint.method} $url",
            requestBody = body?.toString(),
        )
    }

    private suspend fun runAppScanCheckin(
        currentRef: AccountRef,
        ticket: QrTicket,
        options: SignOptions,
        attempts: MutableList<StrategyAttempt>,
    ): AppScanOutcome {
        val scanEndpoint = profile.endpoint("appScan")
        val scanVars = Template.varsOf("qrRaw" to ticket.raw)
        val scanBase = "${currentRef.account.scheme}://${currentRef.account.host}"
        val scanUrl = api.buildUrl(
            scanBase,
            Template.renderPath(scanEndpoint.path, scanVars),
            Template.renderMap(scanEndpoint.query, scanVars),
        )
        val scanReqBody = scanEndpoint.body?.let { Template.renderBody(it, scanVars) }

        val scanRes = api.call(
            account = currentRef.account,
            endpointName = "appScan",
            vars = scanVars,
        )
        applyAuthUpdateIfChanged(currentRef, scanRes.auth, markOk = scanRes.ok)

        val scanMsg = resolveAttemptMessage(scanRes)
        val scanAttempt = StrategyAttempt(
            strategy = APP_SCAN_STRATEGY_ID,
            httpStatus = scanRes.httpStatus,
            code = scanRes.code,
            message = scanMsg,
            ok = false,
            requestLine = "${scanEndpoint.method} $scanUrl",
            requestBody = scanReqBody?.toString(),
            responseBody = scanRes.body.take(2000),
            elapsedMs = scanRes.elapsedMs,
        )

        if (scanRes.httpStatus == 401 ||
            scanRes.code == 401 ||
            (!scanRes.ok &&
                scanRes.httpStatus != -1 &&
                scanRes.code !in OFFICIAL_NON_AUTH_CODES &&
                !isHtmlBody(scanRes.body) &&
                matchesAnyKeyword(scanMsg, profile.result.authKeywords))
        ) {
            attempts += scanAttempt
            // x-client: app 扫码鉴权失败不直接误杀 Web 会话账号，交由后续 X-Client: web 发现与策略链验证
            return AppScanOutcome.Fallthrough(
                discoveredContext = null,
                bestFailure = scanAttempt to SignState.AUTH_REQUIRED,
            )
        }

        if (scanRes.httpStatus in 200..299 && profile.result.isOkCode(scanRes.code)) {
            val data = scanRes.data()
            val scanType = data?.firstNonBlankString("type")?.lowercase()
            val scanValue = data?.firstNonBlankString("value", "lesson_id", "lessonId")
            val scanClassroomId = data?.firstNonBlankString("classroom_id", "classroomId") ?: ticket.classroomId

            if (scanType == "login" || scanType == "app_web_login") {
                val msg = "服务端识别为登录二维码而非课堂签到码"
                attempts += scanAttempt.copy(message = msg)
                return AppScanOutcome.Terminal(
                    SignResult(
                        accountId = currentRef.account.id,
                        label = currentRef.account.label,
                        state = SignState.NO_CONTEXT,
                        message = msg,
                        strategy = APP_SCAN_STRATEGY_ID,
                        attempts = attempts,
                    ),
                )
            }
            if (scanType == "classroom") {
                val msg = "这是加班二维码而非签到码（classroomId=${scanValue.orEmpty()}）"
                attempts += scanAttempt.copy(message = msg)
                return AppScanOutcome.Terminal(
                    SignResult(
                        accountId = currentRef.account.id,
                        label = currentRef.account.label,
                        state = SignState.FAILED,
                        message = msg,
                        strategy = APP_SCAN_STRATEGY_ID,
                        attempts = attempts,
                    ),
                )
            }
            if (scanType == "checkin" && !scanValue.isNullOrBlank()) {
                attempts += scanAttempt.copy(ok = true, message = "app/scan 校验通过 (lessonId=$scanValue)")
                val discoveredContext = LessonContext(lessonId = scanValue, classroomId = scanClassroomId)

                val checkinEndpoint = profile.endpoint("checkinAppScan")
                val checkinVars = Template.varsOf("lessonId" to scanValue)
                val checkinBase = "${currentRef.account.scheme}://${currentRef.account.host}"
                val checkinUrl = api.buildUrl(
                    checkinBase,
                    Template.renderPath(checkinEndpoint.path, checkinVars),
                    Template.renderMap(checkinEndpoint.query, checkinVars),
                )
                val checkinReqBody = checkinEndpoint.body?.let { Template.renderBody(it, checkinVars) }

                val (step2Attempt, step2State) = executeAppScanCheckinStep(
                    currentRef = currentRef,
                    checkinEndpoint = checkinEndpoint,
                    checkinVars = checkinVars,
                    checkinUrl = checkinUrl,
                    checkinReqBody = checkinReqBody,
                    strategyId = APP_SCAN_STRATEGY_ID,
                    referer = null,
                    extraHeaders = emptyMap(),
                    attempts = attempts,
                )

                if (step2State == SignState.SUCCESS || step2State == SignState.ALREADY) {
                    val defaultMsg = if (step2State == SignState.ALREADY) "已签到" else "签到成功"
                    return AppScanOutcome.Terminal(
                        SignResult(
                            accountId = currentRef.account.id,
                            label = currentRef.account.label,
                            state = step2State,
                            message = step2Attempt.message?.takeIf { it.isNotBlank() } ?: defaultMsg,
                            strategy = APP_SCAN_STRATEGY_ID,
                            lessonId = scanValue,
                            attempts = attempts,
                        ),
                    )
                }

                var effectiveAttempt = step2Attempt
                var effectiveState = step2State
                var effectiveStrategy = APP_SCAN_STRATEGY_ID

                if (step2State == SignState.AUTH_REQUIRED) {
                    // 实网修复：Web sessionid 账号在 x-client: app 下可能收到 code 50000 UNAUTHENTICATED，
                    // 立即切回 X-Client: web 重试同载荷；若仍未通过则继续复用已发现的 lessonId 走 Web 兜底策略链。
                    val webReferer = scanClassroomId?.takeIf { it.isNotBlank() }
                        ?.let { "$checkinBase/v2/web/studentLog/$it" }
                        ?: "$checkinBase/v2/web/index"
                    val (webAttempt, webState) = executeAppScanCheckinStep(
                        currentRef = currentRef,
                        checkinEndpoint = checkinEndpoint,
                        checkinVars = checkinVars,
                        checkinUrl = checkinUrl,
                        checkinReqBody = checkinReqBody,
                        strategyId = APP_SCAN_WEB_STRATEGY_ID,
                        referer = webReferer,
                        extraHeaders = mapOf("X-Client" to "web"),
                        attempts = attempts,
                    )
                    effectiveAttempt = webAttempt
                    effectiveState = webState
                    effectiveStrategy = APP_SCAN_WEB_STRATEGY_ID

                    if (webState == SignState.SUCCESS || webState == SignState.ALREADY) {
                        val defaultMsg = if (webState == SignState.ALREADY) "已签到" else "签到成功"
                        return AppScanOutcome.Terminal(
                            SignResult(
                                accountId = currentRef.account.id,
                                label = currentRef.account.label,
                                state = webState,
                                message = webAttempt.message?.takeIf { it.isNotBlank() } ?: defaultMsg,
                                strategy = APP_SCAN_WEB_STRATEGY_ID,
                                lessonId = scanValue,
                                attempts = attempts,
                            ),
                        )
                    }
                }

                if (effectiveState == SignState.TICKET_EXPIRED && options.stopWhenTicketExpired) {
                    return AppScanOutcome.Terminal(
                        SignResult(
                            accountId = currentRef.account.id,
                            label = currentRef.account.label,
                            state = SignState.TICKET_EXPIRED,
                            message = effectiveAttempt.message?.takeIf { it.isNotBlank() } ?: "二维码已过期",
                            strategy = effectiveStrategy,
                            lessonId = scanValue,
                            attempts = attempts,
                        ),
                    )
                }
                return AppScanOutcome.Fallthrough(
                    discoveredContext = discoveredContext,
                    bestFailure = effectiveAttempt to effectiveState,
                )
            }
        }

        if (scanRes.code == 51203) {
            val expiredMsg = scanRes.message?.takeIf { it.isNotBlank() } ?: "二维码无效或已过期（51203）"
            val updatedAttempt = scanAttempt.copy(message = expiredMsg)
            attempts += updatedAttempt
            if (options.stopWhenTicketExpired && matchesAnyKeyword(expiredMsg, APP_SCAN_EXPIRED_KEYWORDS)) {
                return AppScanOutcome.Terminal(
                    SignResult(
                        accountId = currentRef.account.id,
                        label = currentRef.account.label,
                        state = SignState.TICKET_EXPIRED,
                        message = expiredMsg,
                        strategy = APP_SCAN_STRATEGY_ID,
                        lessonId = ticket.lessonId,
                        attempts = attempts,
                    ),
                )
            }
            return AppScanOutcome.Fallthrough(
                discoveredContext = null,
                bestFailure = updatedAttempt to SignState.FAILED,
            )
        }

        // HTTP 404/405/5xx、网络异常或旧模拟服务未实现 /api/v3/app/scan：记录轨迹并安全回退
        attempts += scanAttempt
        return AppScanOutcome.Fallthrough(discoveredContext = null, bestFailure = null)
    }

    private suspend fun executeAppScanCheckinStep(
        currentRef: AccountRef,
        checkinEndpoint: EndpointSpec,
        checkinVars: Map<String, JsonElement>,
        checkinUrl: String,
        checkinReqBody: JsonObject?,
        strategyId: String,
        referer: String?,
        extraHeaders: Map<String, String>,
        attempts: MutableList<StrategyAttempt>,
    ): Pair<StrategyAttempt, SignState> {
        val initialRes = api.call(
            account = currentRef.account,
            endpointName = "checkinAppScan",
            vars = checkinVars,
            referer = referer,
            extraHeaders = extraHeaders,
        )
        val initialRawAttempt = StrategyAttempt(
            strategy = strategyId,
            httpStatus = initialRes.httpStatus,
            code = initialRes.code,
            message = resolveAttemptMessage(initialRes),
            ok = initialRes.ok,
            requestLine = "${checkinEndpoint.method} $checkinUrl",
            requestBody = checkinReqBody?.toString(),
            responseBody = initialRes.body.take(2000),
            elapsedMs = initialRes.elapsedMs,
        )
        val initialState = classify(initialRawAttempt)
        val initialOk = initialState == SignState.SUCCESS || initialState == SignState.ALREADY
        val initialAttempt = initialRawAttempt.copy(ok = initialOk)
        attempts += initialAttempt

        val hasBearer = !currentRef.account.bearer.isNullOrBlank()
        val hasSession = !currentRef.account.sessionId.isNullOrBlank()
        if (initialState == SignState.AUTH_REQUIRED && hasBearer && hasSession) {
            val cookieOnlyAccount = currentRef.account.copy(bearer = null)
            val retryRes = api.call(
                account = cookieOnlyAccount,
                endpointName = "checkinAppScan",
                vars = checkinVars,
                referer = referer,
                extraHeaders = extraHeaders,
            )
            val retryRawAttempt = StrategyAttempt(
                strategy = strategyId,
                httpStatus = retryRes.httpStatus,
                code = retryRes.code,
                message = resolveAttemptMessage(retryRes),
                ok = retryRes.ok,
                requestLine = "${checkinEndpoint.method} $checkinUrl",
                requestBody = checkinReqBody?.toString(),
                responseBody = retryRes.body.take(2000),
                elapsedMs = retryRes.elapsedMs,
            )
            val retryState = classify(retryRawAttempt)
            val retryOk = retryState == SignState.SUCCESS || retryState == SignState.ALREADY
            val retryAttempt = retryRawAttempt.copy(ok = retryOk)
            attempts += retryAttempt

            val cookieAccepted = retryOk ||
                (retryRes.httpStatus in 200..299 && retryState != SignState.AUTH_REQUIRED && retryState != SignState.ERROR)
            if (cookieAccepted) {
                val refreshed = retryRes.auth?.applyTo(cookieOnlyAccount, markOk = retryOk)
                    ?: if (retryOk) cookieOnlyAccount.copy(lastOkAt = nowMillis()) else cookieOnlyAccount
                currentRef.account = refreshed
                updateMutex.withLock {
                    onAccountUpdated(refreshed)
                }
            }
            return retryAttempt to retryState
        }

        applyAuthUpdateIfChanged(currentRef, initialRes.auth, markOk = initialOk)
        return initialAttempt to initialState
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
        val headers = Template.renderMap(endpoint.headers, vars)
        return PlanBuildResult.Ready(RequestPlan(endpoint.method, url, body, headers))
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
            val referer = if (isQrUrlStrategy(spec.id)) {
                extractOrigin(plan.url)?.let { "$it/v2/web/index" } ?: "$base/v2/web/index"
            } else {
                context?.classroomId?.let { "$base/v2/web/studentLog/$it" } ?: "$base/v2/web/index"
            }

            val result = api.raw(
                account = activeAccount,
                method = plan.method,
                url = plan.url,
                body = plan.body,
                referer = referer,
                extraHeaders = plan.headers,
            )

            val rawAttempt = StrategyAttempt(
                strategy = spec.id,
                httpStatus = result.httpStatus,
                code = result.code,
                message = resolveAttemptMessage(result),
                ok = result.ok,
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
        ticket.params.forEach { (k, v) ->
            if (v.isNotBlank()) put(k, JsonPrimitive(v))
        }
        context?.lessonId?.takeIf { it.isNotBlank() }?.let { put("lessonId", JsonPrimitive(it)) }
        context?.classroomId?.takeIf { it.isNotBlank() }?.let { put("classroomId", JsonPrimitive(it)) }
        ticket.checkinId?.takeIf { it.isNotBlank() }?.let { put("checkinId", JsonPrimitive(it)) }
        put("qrRaw", JsonPrimitive(ticket.raw))
        account.userId?.let { put("userId", JsonPrimitive(it)) }
        spec.vars.forEach { (k, v) -> put(k, v) }
    }

    /**
     * 统一状态分类器（严格优先级，与 iOS `CheckInOrchestrator` 对齐）：
     *  1. 网络异常 (`httpStatus == -1`) -> [SignState.ERROR]（绝不误判为 AUTH_REQUIRED）
     *  2. HTTP 401 -> [SignState.AUTH_REQUIRED]（优先于 alreadyKeywords）
     *  3. 非 401/403/5xx 响应命中 `alreadyKeywords` -> [SignState.ALREADY]（优先于 `okCodes`！）
     *  4. HTTP 2xx 且 `code in okCodes`（或 `{"success": true}`）-> [SignState.SUCCESS]
     *  5. `code == 401` -> [SignState.AUTH_REQUIRED]
     *  6. IPA 1.3.6 官方实证业务码优先归类（`50019/50015/50017/50004/50021/50023/50003/50070/51203`），
     *     防止 `50019`「学校身份」命中 `authKeywords` 误判登录过期，或 `50070` 命中 `expiredKeywords` 过早截断兜底
     *  7. HTTP 403 若非非鉴权业务拒绝体则判 [SignState.AUTH_REQUIRED]
     *  8. 非 HTML 响应命中 `authKeywords`（大小写不敏感，含 HTTP 200 业务鉴权失败）-> [SignState.AUTH_REQUIRED]
     *  9. 非 404 路由缺失响应命中 `expiredKeywords`（大小写不敏感）-> [SignState.TICKET_EXPIRED]
     * 10. 可重试状态码 / 5xx -> [SignState.ERROR]
     * 11. 其他 -> [SignState.FAILED]
     */
    internal fun classify(attempt: StrategyAttempt): SignState {
        val status = attempt.httpStatus
        if (status == -1) return SignState.ERROR
        if (status == 401) return SignState.AUTH_REQUIRED

        val rawText = attempt.message?.takeIf { it.isNotBlank() } ?: attempt.responseBody.orEmpty()
        val nonHtmlText = if (isHtmlBody(rawText)) "" else rawText
        val isServerOrRetryableError = status != null &&
            (status >= 500 || profile.result.retryHttpStatus.contains(status))

        if (status != null && status != 403 && !isServerOrRetryableError &&
            matchesAnyKeyword(nonHtmlText, profile.result.alreadyKeywords)
        ) {
            return SignState.ALREADY
        }
        if (status != null && status in 200..299 && (profile.result.isOkCode(attempt.code) || attempt.ok)) {
            return SignState.SUCCESS
        }
        if (attempt.code == 401) {
            return SignState.AUTH_REQUIRED
        }

        // 官方雨课堂 1.3.6 实证业务码优先归类（与 iOS CheckInOrchestrator 保持一致）
        when (attempt.code) {
            50019, 50015, 50017, 50004, 50021, 50023, 50003 -> return SignState.FAILED
            50070 -> return SignState.FAILED
            51203 -> {
                return if (matchesAnyKeyword(nonHtmlText, APP_SCAN_EXPIRED_KEYWORDS)) {
                    SignState.TICKET_EXPIRED
                } else {
                    SignState.FAILED
                }
            }
        }

        if (status == 403) {
            val isNonAuthBusinessRejection = attempt.code != null &&
                attempt.code != 40100 &&
                attempt.code != 40301 &&
                !matchesAnyKeyword(nonHtmlText, profile.result.authKeywords + listOf("csrf", "forbidden"))
            if (!isNonAuthBusinessRejection) {
                return SignState.AUTH_REQUIRED
            }
        }

        if (matchesAnyKeyword(nonHtmlText, profile.result.authKeywords)) {
            return SignState.AUTH_REQUIRED
        }
        val isNotFoundRoute = status == 404 && (
            rawText.isBlank() ||
                isHtmlBody(rawText) ||
                rawText.contains("接口不存在", ignoreCase = true) ||
                rawText.contains("未知路径", ignoreCase = true) ||
                rawText.contains("not found", ignoreCase = true)
        )
        if (!isNotFoundRoute && matchesAnyKeyword(nonHtmlText, profile.result.expiredKeywords)) {
            return SignState.TICKET_EXPIRED
        }
        if (isServerOrRetryableError) {
            return SignState.ERROR
        }
        return SignState.FAILED
    }

    private fun resolveAttemptMessage(result: ApiResult): String {
        val direct = result.message?.takeIf { it.isNotBlank() }
        if (direct != null) return direct
        val mapped = officialErrorMessage(result.code)
        if (mapped != null) return mapped
        val trimmedBody = result.body.trim()
        if (trimmedBody.isEmpty()) {
            return if (result.httpStatus > 0) "HTTP ${result.httpStatus}（空响应）" else "网络异常"
        }
        if (isHtmlBody(trimmedBody)) {
            return "服务器返回 HTML 页面（HTTP ${result.httpStatus}）"
        }
        return trimmedBody.take(160)
    }

    private fun officialErrorMessage(code: Int?): String? = when (code) {
        51203 -> "二维码无效或已过期（51203）"
        50070 -> "动态二维码校验未通过或课堂已结束（50070）"
        50019, 50015 -> "账号未绑定学校身份（$code）"
        50017 -> "教师已设置入班限制（50017）"
        50004 -> "课堂已结束，无法签到（50004）"
        50021 -> "课堂人数已达上限（50021）"
        50023, 50003 -> "课堂或签到码不存在（$code）"
        else -> null
    }

    private fun isMoreInformativeFailure(candidate: StrategyAttempt, existing: StrategyAttempt?): Boolean {
        if (existing == null) return true
        return failureInformativeScore(candidate) > failureInformativeScore(existing)
    }

    private fun failureInformativeScore(attempt: StrategyAttempt): Int {
        val status = attempt.httpStatus ?: return 1
        if (status == -1) return 2
        if (status == 404 || status == 405) return 2
        val msg = attempt.message.orEmpty()
        if (msg.isBlank() || isHtmlBody(msg) || msg.startsWith("服务器返回 HTML")) return 3
        var score = 4
        if (attempt.code != null) score += 2
        if (classify(attempt) == SignState.AUTH_REQUIRED) score += 2
        if (attempt.code in OFFICIAL_NON_AUTH_CODES) score += 3
        return score
    }

    private fun isHtmlBody(text: String): Boolean {
        val trimmed = text.trimStart()
        return trimmed.startsWith("<!DOCTYPE", ignoreCase = true) ||
            trimmed.startsWith("<html", ignoreCase = true) ||
            trimmed.startsWith("<head", ignoreCase = true) ||
            trimmed.startsWith("<body", ignoreCase = true)
    }

    private fun extractOrigin(url: String): String? {
        val scheme = QrParser.extractScheme(url) ?: return null
        val host = QrParser.extractHost(url) ?: return null
        val normalizedHost = when {
            scheme == "https" && host.endsWith(":443") -> host.removeSuffix(":443")
            scheme == "http" && host.endsWith(":80") -> host.removeSuffix(":80")
            else -> host
        }
        return "$scheme://$normalizedHost"
    }

    private fun matchesAnyKeyword(text: String, keywords: List<String>): Boolean {
        if (text.isBlank()) return false
        return keywords.any { kw -> kw.isNotBlank() && text.contains(kw, ignoreCase = true) }
    }

    private fun isQrUrlStrategy(id: String): Boolean =
        id == "QR_URL_POST" || id == "QR_URL_GET"

    // ---------------------------------------------------------------- 解析辅助

    private fun extractLessonsFromResponse(active: ApiResult): List<LessonContext> {
        val dataObj = active.data()
        if (dataObj != null) {
            val fromData = findLessonObjects(dataObj)
            if (fromData.isNotEmpty()) return fromData
        }
        val root = active.json
        if (root != null) {
            val fromRoot = findLessonObjects(root)
            if (fromRoot.isNotEmpty()) return fromRoot
            val dataArr = root["data"] as? JsonArray
            if (dataArr != null) {
                val fromArr = parseLessonArray(dataArr)
                if (fromArr.isNotEmpty()) return fromArr
            }
        }
        return emptyList()
    }

    private fun findLessonObjects(data: JsonObject): List<LessonContext> {
        val arrays = listOf("onLessonClassrooms", "classrooms", "lessonList", "lessons")
        for (key in arrays) {
            val array = data[key] as? JsonArray ?: continue
            val parsed = parseLessonArray(array)
            if (parsed.isNotEmpty()) return parsed
        }
        return emptyList()
    }

    private fun parseLessonArray(array: JsonArray): List<LessonContext> =
        array.mapNotNull { element ->
            val obj = element as? JsonObject ?: return@mapNotNull null
            val lessonId = obj.firstNonBlankString("lessonId", "lesson_id", "id", "courseId")
            if (lessonId.isNullOrBlank()) return@mapNotNull null
            LessonContext(
                lessonId = lessonId,
                classroomId = obj.firstNonBlankString("classroomId", "classroom_id"),
                name = obj.firstNonBlankString("courseName", "lessonName", "name", "title"),
            )
        }

    private class AccountRef(var account: Account)

    private data class RequestPlan(
        val method: String,
        val url: String,
        val body: JsonObject?,
        val headers: Map<String, String> = emptyMap(),
    )

    private sealed class PlanBuildResult {
        data class Ready(val plan: RequestPlan) : PlanBuildResult()
        data class Rejected(val reason: String) : PlanBuildResult()
    }

    private sealed class AppScanOutcome {
        data class Terminal(val result: SignResult) : AppScanOutcome()
        data class Fallthrough(
            val discoveredContext: LessonContext?,
            val bestFailure: Pair<StrategyAttempt, SignState>?,
        ) : AppScanOutcome()
    }

    private sealed class DiscoverOutcome {
        data class Found(val context: LessonContext) : DiscoverOutcome()
        data class AuthRequired(val message: String, val attempt: StrategyAttempt) : DiscoverOutcome()
        data class NetworkError(val message: String, val attempt: StrategyAttempt) : DiscoverOutcome()
        data class NotFound(val message: String, val attempt: StrategyAttempt?) : DiscoverOutcome()
    }

    private companion object {
        const val APP_SCAN_STRATEGY_ID = "APP_SCAN_CHECKIN"
        const val APP_SCAN_WEB_STRATEGY_ID = "APP_SCAN_CHECKIN_WEB"
        val OFFICIAL_NON_AUTH_CODES = setOf(51203, 50070, 50019, 50015, 50017, 50004, 50021, 50023, 50003)
        val APP_SCAN_EXPIRED_KEYWORDS = listOf("过期", "失效", "expired", "refused", "二维码已")
    }
}
