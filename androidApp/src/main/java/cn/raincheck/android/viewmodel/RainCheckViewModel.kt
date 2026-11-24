package cn.raincheck.android.viewmodel

import android.app.Application
import android.content.Context
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import cn.raincheck.android.RainCheckApp
import cn.raincheck.android.data.ReportExporter
import cn.raincheck.core.Account
import cn.raincheck.core.Edition
import cn.raincheck.core.QrParser
import cn.raincheck.core.QrTicket
import cn.raincheck.core.SignBatchReport
import cn.raincheck.core.SignInEngine
import cn.raincheck.core.SignOptions
import cn.raincheck.core.SignResult
import cn.raincheck.core.SignState
import cn.raincheck.core.TicketKind
import cn.raincheck.core.nowMillis
import cn.raincheck.core.randomId
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import java.io.File
import java.util.concurrent.atomic.AtomicLong

enum class NavTab(val key: String) {
    SIGN("sign"),
    ACCOUNTS("accounts"),
    RESULTS("results"),
}

enum class ResultFilter {
    ALL,
    SUCCESS,
    ALREADY,
    DRY_RUN,
    AUTH_REQUIRED,
    TICKET_EXPIRED,
    NO_CONTEXT,
    FAILED,
    ERROR,
}

data class SignUiSettings(
    val concurrency: Int = 4,
    val staggerMs: Long = 60L,
    val maxAttemptsPerStrategy: Int = 3,
    val stopWhenTicketExpired: Boolean = true,
    val dryRun: Boolean = false,
    val onlyEnabled: Boolean = true,
)

data class UiNotice(
    val id: Long,
    val message: String,
    val isError: Boolean = false,
)

data class RainCheckUiState(
    val selectedTab: NavTab = NavTab.SIGN,
    val accounts: List<Account> = emptyList(),
    val storageError: String? = null,
    val usedFallbackProfile: Boolean = false,
    val rawQrInput: String = "",
    val ticket: QrTicket? = null,
    val ticketParsedAtMillis: Long? = null,
    val ticketDomainWarning: String? = null,
    val settings: SignUiSettings = SignUiSettings(),
    /** 非空时表示用户手动勾选了本次签到目标账号集合，绝不修改账号本身的 enabled 状态。 */
    val customSelectedAccountIds: Set<String>? = null,
    val isSigning: Boolean = false,
    val isRetrying: Boolean = false,
    val liveLogs: List<String> = emptyList(),
    val report: SignBatchReport? = null,
    val resultFilter: ResultFilter = ResultFilter.ALL,
    /** 按 accountId 记住报文展开态，列表刷新/重试时不丢失。 */
    val expandedAccountIds: Set<String> = emptySet(),
    val verifyingAccountIds: Set<String> = emptySet(),
    val showScanner: Boolean = false,
    val showAddAccountSheet: Boolean = false,
    val showQrLoginSheet: Boolean = false,
    val pendingShareFile: File? = null,
    val notice: UiNotice? = null,
) {
    /** 计算本次将参与签到的目标账号（绝不修改持久化 enabled 字段）。 */
    fun effectiveTargetAccounts(): List<Account> {
        val custom = customSelectedAccountIds
        return when {
            custom != null -> accounts.filter { it.id in custom }
            settings.onlyEnabled -> accounts.filter { it.enabled }
            else -> accounts
        }
    }
}

/**
 * 全局统一状态层：基于 [AndroidViewModel] + [StateFlow] + [viewModelScope]。
 *
 * 配置变更（深浅色切换、旋转、字体缩放）与切后台期间协程稳定执行，
 * 不再依赖 Fragment 生命周期与 `FragmentTransaction.commit()`，彻底消除切页不刷新与后台闪退。
 */
class RainCheckViewModel(application: Application) : AndroidViewModel(application) {

    private val app: RainCheckApp = application as RainCheckApp
    private val prefs = application.getSharedPreferences(PREF_SETTINGS, Context.MODE_PRIVATE)
    private val noticeSeq = AtomicLong(0L)

    private val _uiState = MutableStateFlow(
        RainCheckUiState(
            accounts = app.accountStore.accountsFlow.value,
            storageError = app.accountStore.storageError.value,
            usedFallbackProfile = app.usedFallbackProfile,
            settings = loadSettings(),
        ),
    )
    val uiState: StateFlow<RainCheckUiState> = _uiState.asStateFlow()

    val editions: List<Edition>
        get() = app.profile.editions.ifEmpty { Edition.presets }

    val defaultEdition: Edition
        get() = editions.firstOrNull { it.id == app.profile.defaultEdition }
            ?: editions.firstOrNull()
            ?: Edition.WWW

    private var signJob: Job? = null
    private var retryJob: Job? = null

    init {
        viewModelScope.launch {
            app.accountStore.accountsFlow.collect { latest ->
                _uiState.update { state ->
                    val existingIds = latest.mapTo(HashSet()) { it.id }
                    val prunedCustom = state.customSelectedAccountIds?.filterTo(LinkedHashSet()) { it in existingIds }
                    val prunedExpanded = state.expandedAccountIds.filterTo(LinkedHashSet()) { it in existingIds }
                    state.copy(
                        accounts = latest,
                        customSelectedAccountIds = prunedCustom,
                        expandedAccountIds = prunedExpanded,
                        ticketDomainWarning = state.ticket?.let { evaluateDomainWarning(it, latest) },
                    )
                }
            }
        }
        viewModelScope.launch {
            app.accountStore.storageError.collect { err ->
                _uiState.update { it.copy(storageError = err) }
            }
        }
    }

    // ------------------------------------------------------------------ 导航与弹窗

    fun selectTab(tab: NavTab) {
        _uiState.update { it.copy(selectedTab = tab) }
    }

    fun openScanner() {
        _uiState.update { it.copy(showScanner = true) }
    }

    fun closeScanner() {
        _uiState.update { it.copy(showScanner = false) }
    }

    fun openAddAccountSheet() {
        _uiState.update { it.copy(showAddAccountSheet = true) }
    }

    fun closeAddAccountSheet() {
        _uiState.update { it.copy(showAddAccountSheet = false) }
    }

    fun openQrLoginSheet() {
        _uiState.update { it.copy(showQrLoginSheet = true) }
    }

    fun closeQrLoginSheet() {
        _uiState.update { it.copy(showQrLoginSheet = false) }
    }

    fun consumeNotice(id: Long) {
        _uiState.update { state ->
            if (state.notice?.id == id) state.copy(notice = null) else state
        }
    }

    fun consumePendingShare() {
        _uiState.update { it.copy(pendingShareFile = null) }
    }

    fun dismissStorageError() {
        app.accountStore.dismissStorageError()
    }

    // ------------------------------------------------------------------ 二维码解析（绝不自动提交）

    fun updateRawQrInput(text: String) {
        _uiState.update { it.copy(rawQrInput = text) }
    }

    fun clearTicket() {
        _uiState.update {
            it.copy(
                rawQrInput = "",
                ticket = null,
                ticketParsedAtMillis = null,
                ticketDomainWarning = null,
            )
        }
    }

    fun onQrScanned(rawContent: String) {
        _uiState.update { it.copy(showScanner = false) }
        parseTicket(rawContent, fromScanner = true)
    }

    fun parseTicket(rawInput: String, fromScanner: Boolean = false) {
        val trimmed = rawInput.trim()
        if (trimmed.isEmpty()) {
            postNotice("请先扫描或粘贴二维码内容", isError = true)
            return
        }
        val parsed = QrParser.parse(trimmed, app.profile)
        val warning = evaluateDomainWarning(parsed, _uiState.value.accounts)
        _uiState.update {
            it.copy(
                rawQrInput = trimmed,
                ticket = parsed,
                ticketParsedAtMillis = nowMillis(),
                ticketDomainWarning = warning,
            )
        }
        when {
            parsed.kind == TicketKind.LOGIN ->
                postNotice("检测到登录二维码，请前往「账号舱」使用扫码登录", isError = true)
            warning != null ->
                postNotice("注意：二维码域名不在白名单内，请谨慎核对", isError = true)
            parsed.kind == TicketKind.UNKNOWN ->
                postNotice("已解析文本，但未识别为标准雨课堂二维码")
            fromScanner ->
                postNotice("已识别二维码，确认参数后点击下方开始签到")
            else ->
                postNotice("已解析：${parsed.summary()}")
        }
    }

    // ------------------------------------------------------------------ 签到参数与账号选择

    fun updateSettings(transform: (SignUiSettings) -> SignUiSettings) {
        val next = transform(_uiState.value.settings).let { s ->
            s.copy(
                concurrency = s.concurrency.coerceIn(1, 32),
                staggerMs = s.staggerMs.coerceIn(0L, 1000L),
                maxAttemptsPerStrategy = s.maxAttemptsPerStrategy.coerceIn(1, 5),
            )
        }
        persistSettings(next)
        _uiState.update { state ->
            val clearCustom = state.settings.onlyEnabled != next.onlyEnabled
            state.copy(
                settings = next,
                customSelectedAccountIds = if (clearCustom) null else state.customSelectedAccountIds,
            )
        }
    }

    /** 切换某个账号在“本次签到”中的选中态，绝不修改该账号持久化的 enabled 开关。 */
    fun toggleTargetAccountForRun(accountId: String) {
        _uiState.update { state ->
            val currentIds = state.customSelectedAccountIds
                ?: state.effectiveTargetAccounts().mapTo(LinkedHashSet()) { it.id }
            val nextIds = currentIds.toMutableSet()
            if (!nextIds.add(accountId)) {
                nextIds.remove(accountId)
            }
            state.copy(customSelectedAccountIds = nextIds)
        }
    }

    fun selectAllAccountsForRun() {
        _uiState.update { state ->
            state.copy(customSelectedAccountIds = state.accounts.mapTo(LinkedHashSet()) { it.id })
        }
    }

    fun resetTargetAccountsToEnabled() {
        updateSettings { it.copy(onlyEnabled = true) }
        _uiState.update { it.copy(customSelectedAccountIds = null) }
    }

    // ------------------------------------------------------------------ 并发签到执行

    fun startSign() {
        val snapshot = _uiState.value
        val currentTicket = snapshot.ticket
        if (currentTicket == null) {
            postNotice("请先扫描或粘贴签到二维码", isError = true)
            return
        }
        if (currentTicket.kind == TicketKind.LOGIN) {
            postNotice("这是登录二维码，已拦截签到；请到「账号舱」扫码登录", isError = true)
            return
        }
        if (signJob?.isActive == true) return

        val targets = snapshot.effectiveTargetAccounts()
        if (targets.isEmpty()) {
            postNotice("当前没有选中的签到账号，请先在账号舱添加或勾选", isError = true)
            return
        }

        val options = buildSignOptions(snapshot.settings)
        _uiState.update {
            it.copy(
                isSigning = true,
                liveLogs = listOf(
                    if (options.dryRun) {
                        "▶ 开始演练：${targets.size} 个账号 · 并发 ${options.concurrency} · 错开 ${options.staggerMs}ms（零网络请求）"
                    } else {
                        "▶ 开始并发签到：${targets.size} 个账号 · 并发 ${options.concurrency} · 错开 ${options.staggerMs}ms · 重试 ${options.maxAttemptsPerStrategy} 次"
                    },
                ),
            )
        }

        val engine = app.engineWith { line -> appendLog(line) }
        signJob = viewModelScope.launch {
            try {
                val report = withContext(Dispatchers.IO) {
                    runBatchPreservingEnabled(engine, targets, currentTicket, options)
                }
                val summary = if (report.dryRunCount > 0) {
                    "✔ 演练完成：模拟 ${report.dryRunCount} · 成功 ${report.successCount} · 失败 ${report.failedCount} · 耗时 ${report.elapsedMs}ms"
                } else {
                    "✔ 完成：成功 ${report.successCount} · 失败 ${report.failedCount} · 耗时 ${report.elapsedMs}ms"
                }
                appendLog(summary)
                _uiState.update {
                    it.copy(
                        isSigning = false,
                        report = report,
                        resultFilter = ResultFilter.ALL,
                        selectedTab = NavTab.RESULTS,
                    )
                }
                postNotice(summary)
            } catch (e: CancellationException) {
                _uiState.update { it.copy(isSigning = false) }
                throw e
            } catch (e: Throwable) {
                val msg = e.message ?: e.javaClass.simpleName
                appendLog("✖ 签到异常：$msg")
                _uiState.update { it.copy(isSigning = false) }
                postNotice("签到执行失败：$msg", isError = true)
            }
        }
    }

    fun clearLogs() {
        _uiState.update { it.copy(liveLogs = emptyList()) }
    }

    // ------------------------------------------------------------------ 报文实验室：筛选、展开、重试、安全导出

    fun setResultFilter(filter: ResultFilter) {
        _uiState.update { it.copy(resultFilter = filter) }
    }

    fun toggleResultExpanded(accountId: String) {
        _uiState.update { state ->
            val next = state.expandedAccountIds.toMutableSet()
            if (!next.add(accountId)) next.remove(accountId)
            state.copy(expandedAccountIds = next)
        }
    }

    /**
     * 重试失败项：
     * - 严格绑定 `report.ticket`，绝不混用新扫的二维码；
     * - 绝不污染全局 `settings`（尤其是 `dryRun`）；
     * - 绝不用 `.copy(enabled = true)` 污染回写账号的 `enabled` 状态。
     */
    fun retryFailed() {
        val currentReport = _uiState.value.report
        if (currentReport == null) {
            postNotice("当前没有可重试的批次报告", isError = true)
            return
        }
        if (retryJob?.isActive == true || _uiState.value.isSigning) return

        val failed = currentReport.results.filter { !it.ok && it.state != SignState.DRY_RUN }
        if (failed.isEmpty()) {
            postNotice("当前批次没有需要重试的失败项")
            return
        }

        val latestById = app.accountStore.load().associateBy { it.id }
        val targets = failed.mapNotNull { latestById[it.accountId] }
        if (targets.isEmpty()) {
            postNotice("失败项对应的账号已不存在，请检查账号舱", isError = true)
            return
        }

        // 本地副本选项：强制真实提交而不覆盖用户全局 settings.dryRun
        val retryOptions = buildSignOptions(_uiState.value.settings).copy(dryRun = false)
        val boundTicket = currentReport.ticket
        val engine = app.engineWith { line -> appendLog("[重试] $line") }

        _uiState.update { it.copy(isRetrying = true) }
        retryJob = viewModelScope.launch {
            try {
                val retried = withContext(Dispatchers.IO) {
                    runBatchPreservingEnabled(engine, targets, boundTicket, retryOptions)
                }
                val merged = mergeReports(currentReport, retried)
                _uiState.update {
                    it.copy(
                        isRetrying = false,
                        report = merged,
                    )
                }
                postNotice("重试完成：${targets.size} 个账号（本批累计成功 ${merged.successCount}）")
            } catch (e: CancellationException) {
                _uiState.update { it.copy(isRetrying = false) }
                throw e
            } catch (e: Throwable) {
                _uiState.update { it.copy(isRetrying = false) }
                postNotice("重试失败：${e.message ?: e.javaClass.simpleName}", isError = true)
            }
        }
    }

    fun exportAndShareReport() {
        val currentReport = _uiState.value.report
        if (currentReport == null || currentReport.results.isEmpty()) {
            postNotice("还没有可导出的签到结果", isError = true)
            return
        }
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching { ReportExporter.export(app, currentReport) }
            }
            result.onSuccess { file ->
                _uiState.update { it.copy(pendingShareFile = file) }
                postNotice("已生成脱敏报告：${file.name}")
            }.onFailure { err ->
                postNotice("导出失败：${err.message ?: err.javaClass.simpleName}", isError = true)
            }
        }
    }

    // ------------------------------------------------------------------ 账号舱操作

    fun addManualAccount(
        label: String,
        host: String,
        scheme: String,
        bearer: String?,
        sessionId: String?,
        csrfToken: String?,
        note: String,
    ) {
        val cleanBearer = stripBearerPrefix(bearer)
        val cleanSession = sessionId?.trim()?.takeIf { it.isNotEmpty() }
        val cleanCsrf = csrfToken?.trim()?.takeIf { it.isNotEmpty() }
        val cleanHost = host.trim()
        val cleanScheme = scheme.trim().lowercase().ifEmpty { "https" }

        val account = Account(
            id = randomId(),
            label = label.trim(),
            host = cleanHost,
            scheme = cleanScheme,
            bearer = cleanBearer,
            sessionId = cleanSession,
            csrfToken = cleanCsrf,
            enabled = true,
            createdAt = nowMillis(),
            note = note.trim(),
        )
        app.accountStore.upsert(account)
        _uiState.update { it.copy(showAddAccountSheet = false) }
        postNotice("已加密保存账号「${account.label}」")
    }

    fun onQrLoginAuthorized(account: Account) {
        app.accountStore.upsert(account)
        postNotice("扫码登录成功：${account.label}")
    }

    fun toggleAccountEnabled(account: Account, enabled: Boolean) {
        app.accountStore.upsert(account.copy(enabled = enabled))
        postNotice(if (enabled) "已启用「${account.label}」" else "已停用「${account.label}」")
    }

    fun deleteAccount(account: Account) {
        app.accountStore.remove(account.id)
        postNotice("已删除账号「${account.label}」")
    }

    fun verifyAccount(account: Account) {
        if (account.id in _uiState.value.verifyingAccountIds) return
        _uiState.update { it.copy(verifyingAccountIds = it.verifyingAccountIds + account.id) }
        viewModelScope.launch {
            try {
                val verified = withContext(Dispatchers.IO) {
                    runCatching { app.loginService.verify(account) }.getOrNull()
                }
                if (verified != null) {
                    app.accountStore.updateSessionPreservingEnabled(verified)
                    postNotice("会话有效：${verified.label}")
                } else {
                    postNotice("「${account.label}」会话校验未通过，可能需要重新登录", isError = true)
                }
            } finally {
                _uiState.update { it.copy(verifyingAccountIds = it.verifyingAccountIds - account.id) }
            }
        }
    }

    fun verifyAllAccounts() {
        val current = _uiState.value.accounts.filter { it.hasCredential }
        if (current.isEmpty()) {
            postNotice("没有可校验的账号")
            return
        }
        current.forEach { verifyAccount(it) }
    }

    // ------------------------------------------------------------------ 内部工具

    /**
     * 并发执行指定账号列表，彻底避免 `.copy(enabled = true)` 污染回写：
     * - 当全部目标均已启用时直接调用 [SignInEngine.signInAll]；
     * - 当包含禁用账号（用户手动指定或重试失败项）时直接并发调度 [SignInEngine.signIn]，
     *   既保留并发/错开语义，又绝不篡改任何账号的 `enabled` 标志。
     */
    private suspend fun runBatchPreservingEnabled(
        engine: SignInEngine,
        targets: List<Account>,
        ticket: QrTicket,
        options: SignOptions,
    ): SignBatchReport {
        if (targets.all { it.enabled }) {
            return engine.signInAll(targets, ticket, options)
        }
        val started = nowMillis()
        val semaphore = Semaphore(options.concurrency)
        val results = coroutineScope {
            targets.mapIndexed { index, account ->
                async {
                    if (options.staggerMs > 0) delay(index * options.staggerMs)
                    semaphore.withPermit {
                        try {
                            engine.signIn(account, ticket, options)
                        } catch (e: CancellationException) {
                            throw e
                        } catch (e: Throwable) {
                            SignResult(
                                accountId = account.id,
                                label = account.label,
                                state = SignState.ERROR,
                                message = e.message ?: e.javaClass.simpleName ?: "未知错误",
                            )
                        }
                    }
                }
            }.awaitAll()
        }
        return SignBatchReport(results, started, nowMillis(), ticket)
    }

    private fun mergeReports(old: SignBatchReport, retried: SignBatchReport): SignBatchReport {
        val updated = retried.results.associateBy { it.accountId }
        val merged = old.results.map { updated[it.accountId] ?: it } +
            retried.results.filter { r -> old.results.none { it.accountId == r.accountId } }
        return SignBatchReport(
            results = merged,
            startedAt = old.startedAt,
            finishedAt = retried.finishedAt,
            ticket = old.ticket,
        )
    }

    private fun buildSignOptions(s: SignUiSettings): SignOptions = SignOptions(
        concurrency = s.concurrency.coerceIn(1, 32),
        maxAttemptsPerStrategy = s.maxAttemptsPerStrategy.coerceIn(1, 5),
        baseBackoffMs = 800L,
        stopWhenTicketExpired = s.stopWhenTicketExpired,
        dryRun = s.dryRun,
        staggerMs = s.staggerMs.coerceIn(0L, 1000L),
    )

    private fun evaluateDomainWarning(ticket: QrTicket, accounts: List<Account>): String? {
        val rawUrl = ticket.url ?: return null
        val scheme = rawUrl.substringBefore("://", "").lowercase()
        if (scheme != "https" && scheme != "http") return null

        // 直接复用 core ProtocolProfile.validateQrUrl 单一真源校验逻辑
        val baseReason = app.profile.validateQrUrl(rawUrl, account = null) ?: return null
        val allowedByAnyAccount = accounts.any { acc -> app.profile.isAllowedQrUrl(rawUrl, acc) }
        if (allowedByAnyAccount) return null

        return "$baseReason。引擎已启用严格同源/白名单防护，不会向该第三方或未授权地址外发任何账号凭据。"
    }

    private fun appendLog(line: String) {
        if (line.isBlank()) return
        _uiState.update { state ->
            val updated = (state.liveLogs + line).takeLast(MAX_LOG_LINES)
            state.copy(liveLogs = updated)
        }
    }

    private fun postNotice(message: String, isError: Boolean = false) {
        _uiState.update {
            it.copy(notice = UiNotice(id = noticeSeq.incrementAndGet(), message = message, isError = isError))
        }
    }

    private fun loadSettings(): SignUiSettings = SignUiSettings(
        concurrency = prefs.getInt(KEY_CONCURRENCY, 4).coerceIn(1, 32),
        staggerMs = prefs.getLong(KEY_STAGGER_MS, 60L).coerceIn(0L, 1000L),
        maxAttemptsPerStrategy = prefs.getInt(KEY_MAX_ATTEMPTS, 3).coerceIn(1, 5),
        stopWhenTicketExpired = prefs.getBoolean(KEY_STOP_EXPIRED, true),
        dryRun = prefs.getBoolean(KEY_DRY_RUN, false),
        onlyEnabled = prefs.getBoolean(KEY_ONLY_ENABLED, true),
    )

    private fun persistSettings(s: SignUiSettings) {
        prefs.edit()
            .putInt(KEY_CONCURRENCY, s.concurrency)
            .putLong(KEY_STAGGER_MS, s.staggerMs)
            .putInt(KEY_MAX_ATTEMPTS, s.maxAttemptsPerStrategy)
            .putBoolean(KEY_STOP_EXPIRED, s.stopWhenTicketExpired)
            .putBoolean(KEY_DRY_RUN, s.dryRun)
            .putBoolean(KEY_ONLY_ENABLED, s.onlyEnabled)
            .apply()
    }

    companion object {
        private const val PREF_SETTINGS = "raincheck.settings"
        private const val KEY_CONCURRENCY = "concurrency"
        private const val KEY_STAGGER_MS = "stagger_ms"
        private const val KEY_MAX_ATTEMPTS = "max_attempts"
        private const val KEY_STOP_EXPIRED = "stop_when_expired"
        private const val KEY_DRY_RUN = "dry_run"
        private const val KEY_ONLY_ENABLED = "only_enabled"
        private const val MAX_LOG_LINES = 200

        /** 剥离用户复制时常带的 `Bearer ` 前缀（忽略大小写与空白，同时拦截裸 `Bearer`）。 */
        fun stripBearerPrefix(raw: String?): String? {
            var s = raw?.trim().orEmpty()
            while (
                s.equals("bearer", ignoreCase = true) ||
                (s.length > 6 && s.startsWith("bearer", ignoreCase = true) && s[6].isWhitespace())
            ) {
                s = s.substring(6).trim()
            }
            return s.takeIf { it.isNotEmpty() }
        }
    }
}
