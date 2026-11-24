package cn.raincheck.android.ui.screens

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Bolt
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.ContentPaste
import androidx.compose.material.icons.rounded.DeleteSweep
import androidx.compose.material.icons.rounded.ErrorOutline
import androidx.compose.material.icons.rounded.GppBad
import androidx.compose.material.icons.rounded.Groups
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.QrCode2
import androidx.compose.material.icons.rounded.QrCodeScanner
import androidx.compose.material.icons.rounded.Science
import androidx.compose.material.icons.rounded.Shield
import androidx.compose.material.icons.rounded.Timer
import androidx.compose.material.icons.rounded.WarningAmber
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import cn.raincheck.android.ui.components.AuroraPrimaryButton
import cn.raincheck.android.ui.components.GlassBanner
import cn.raincheck.android.ui.components.GlassCard
import cn.raincheck.android.ui.components.GlassPill
import cn.raincheck.android.ui.components.GlassTonalButton
import cn.raincheck.android.ui.components.SectionHeader
import cn.raincheck.android.ui.theme.RainCheckTheme
import cn.raincheck.android.ui.theme.campusAccentColor
import cn.raincheck.android.viewmodel.NavTab
import cn.raincheck.android.viewmodel.RainCheckUiState
import cn.raincheck.android.viewmodel.RainCheckViewModel
import cn.raincheck.core.QrTicket
import cn.raincheck.core.TicketKind
import kotlinx.coroutines.delay
import kotlin.math.roundToInt

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun SignScreen(
    uiState: RainCheckUiState,
    viewModel: RainCheckViewModel,
) {
    val glass = RainCheckTheme.glass
    val clipboard = LocalClipboardManager.current
    val targets = remember(uiState.accounts, uiState.settings.onlyEnabled, uiState.customSelectedAccountIds) {
        uiState.effectiveTargetAccounts()
    }
    val targetIdSet = remember(targets) { targets.mapTo(HashSet()) { it.id } }

    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .statusBarsPadding(),
        contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 16.dp, bottom = 112.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        // 顶部极光标题区
        item(key = "header") {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(
                        text = "签到台",
                        style = MaterialTheme.typography.headlineLarge,
                        color = glass.inkPrimary,
                    )
                    Text(
                        text = "CameraX 离线解析 · 多账号并发调度",
                        style = MaterialTheme.typography.bodySmall,
                        color = glass.inkSecondary,
                    )
                }
                GlassPill(
                    text = if (uiState.settings.dryRun) "演练模式" else "就绪 ${targets.size} 号",
                    color = if (uiState.settings.dryRun) glass.statusDryRun else glass.accentTeal,
                    showDot = true,
                )
            }
        }

        // 系统警告横幅（降级配置 / 存储损坏备份）
        if (uiState.usedFallbackProfile) {
            item(key = "fallback-banner") {
                GlassBanner(
                    title = "已启用内置协议配置",
                    message = "assets/protocol_profile.json 解析异常，当前已自动切回内置完整协议配置。",
                    accentColor = glass.statusAuth,
                    icon = Icons.Rounded.WarningAmber,
                )
            }
        }
        if (uiState.storageError != null) {
            item(key = "storage-banner") {
                GlassBanner(
                    title = "加密账号库提醒",
                    message = uiState.storageError,
                    accentColor = glass.statusFailed,
                    icon = Icons.Rounded.ErrorOutline,
                    actionLabel = "知道了",
                    onAction = { viewModel.dismissStorageError() },
                )
            }
        }

        // 1. 二维码解析英雄卡
        item(key = "qr-hero") {
            QrHeroCard(
                ticket = uiState.ticket,
                parsedAtMillis = uiState.ticketParsedAtMillis,
                domainWarning = uiState.ticketDomainWarning,
                rawInput = uiState.rawQrInput,
                isSigning = uiState.isSigning,
                onRawInputChange = viewModel::updateRawQrInput,
                onParse = { viewModel.parseTicket(uiState.rawQrInput) },
                onClear = viewModel::clearTicket,
                onOpenScanner = viewModel::openScanner,
                onPaste = {
                    val clip = clipboard.getText()?.text.orEmpty()
                    if (clip.isNotBlank()) {
                        viewModel.parseTicket(clip)
                    } else {
                        viewModel.parseTicket("")
                    }
                },
                onJumpQrLogin = {
                    viewModel.selectTab(NavTab.ACCOUNTS)
                    viewModel.openQrLoginSheet()
                },
            )
        }

        // 2. 账号选择胶囊流
        item(key = "account-pills") {
            GlassCard {
                SectionHeader(
                    title = "参签账号",
                    subtitle = "已选 ${targets.size} / 共 ${uiState.accounts.size} 个（点按可仅针对本次调整，不改动停用状态）",
                    trailing = {
                        if (uiState.accounts.isNotEmpty()) {
                            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                GlassPill(
                                    text = "仅启用",
                                    color = glass.accentTeal,
                                    selected = uiState.customSelectedAccountIds == null && uiState.settings.onlyEnabled,
                                    onClick = viewModel::resetTargetAccountsToEnabled,
                                )
                                GlassPill(
                                    text = "全选",
                                    color = glass.accentIndigo,
                                    selected = uiState.accounts.isNotEmpty() && targets.size == uiState.accounts.size,
                                    onClick = viewModel::selectAllAccountsForRun,
                                )
                            }
                        }
                    },
                )
                Spacer(modifier = Modifier.height(12.dp))
                if (uiState.accounts.isEmpty()) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            text = "账号舱还没有账号，先去扫码登录或手动导入凭据。",
                            style = MaterialTheme.typography.bodySmall,
                            color = glass.inkSecondary,
                            modifier = Modifier.weight(1f),
                        )
                        Spacer(modifier = Modifier.width(8.dp))
                        GlassPill(
                            text = "前往账号舱",
                            color = glass.accentTeal,
                            icon = Icons.Rounded.Groups,
                            selected = true,
                            onClick = { viewModel.selectTab(NavTab.ACCOUNTS) },
                        )
                    }
                } else {
                    FlowRow(
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        uiState.accounts.forEach { account ->
                            val selected = account.id in targetIdSet
                            val campusColor = campusAccentColor(account.host, glass.isDark)
                            val pillColor = when {
                                selected && !account.enabled -> glass.accentIndigo
                                selected -> campusColor
                                else -> glass.inkMuted
                            }
                            val label = buildString {
                                append(account.label)
                                if (!account.enabled) {
                                    append(if (selected) " · 本次临时" else " · 停用")
                                }
                            }
                            GlassPill(
                                text = label,
                                color = pillColor,
                                selected = selected,
                                icon = if (selected) Icons.Rounded.CheckCircle else null,
                                showDot = !selected,
                                onClick = { viewModel.toggleTargetAccountForRun(account.id) },
                            )
                        }
                    }
                }
            }
        }

        // 3. 并发与策略控制卡（1–32 并发、错开延迟、重试次数、遇过期中止、演练模式）
        item(key = "controls") {
            GlassCard {
                SectionHeader(
                    title = "调度参数",
                    subtitle = "账号间并发 · 账号内串行策略链",
                )
                Spacer(modifier = Modifier.height(14.dp))

                // 并发数 1..32
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        text = "并发协程数",
                        style = MaterialTheme.typography.titleSmall,
                        color = glass.inkPrimary,
                    )
                    GlassPill(
                        text = "${uiState.settings.concurrency} 并发（1–32）",
                        color = glass.accentTeal,
                        icon = Icons.Rounded.Bolt,
                    )
                }
                Slider(
                    value = uiState.settings.concurrency.toFloat(),
                    onValueChange = { v ->
                        viewModel.updateSettings { it.copy(concurrency = v.roundToInt().coerceIn(1, 32)) }
                    },
                    valueRange = 1f..32f,
                    steps = 30,
                    enabled = !uiState.isSigning,
                    colors = SliderDefaults.colors(
                        thumbColor = glass.accentTeal,
                        activeTrackColor = glass.accentTeal,
                        inactiveTrackColor = glass.inkMuted.copy(alpha = 0.25f),
                    ),
                )

                // 错开延迟 staggerMs
                Spacer(modifier = Modifier.height(6.dp))
                Text(
                    text = "账号错开延迟（缓解同 IP 瞬时尖峰）",
                    style = MaterialTheme.typography.titleSmall,
                    color = glass.inkPrimary,
                )
                Spacer(modifier = Modifier.height(8.dp))
                FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    listOf(0L, 60L, 120L, 250L, 500L).forEach { ms ->
                        GlassPill(
                            text = if (ms == 0L) "无延迟" else "${ms}ms",
                            color = glass.accentCyan,
                            selected = uiState.settings.staggerMs == ms,
                            onClick = {
                                if (!uiState.isSigning) {
                                    viewModel.updateSettings { it.copy(staggerMs = ms) }
                                }
                            },
                        )
                    }
                }

                // 单策略最大尝试次数
                Spacer(modifier = Modifier.height(14.dp))
                Text(
                    text = "单策略最大尝试次数（仅对网络/5xx/429 退避重试）",
                    style = MaterialTheme.typography.titleSmall,
                    color = glass.inkPrimary,
                )
                Spacer(modifier = Modifier.height(8.dp))
                FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    (1..5).forEach { count ->
                        GlassPill(
                            text = "${count} 次",
                            color = glass.accentIndigo,
                            selected = uiState.settings.maxAttemptsPerStrategy == count,
                            onClick = {
                                if (!uiState.isSigning) {
                                    viewModel.updateSettings { it.copy(maxAttemptsPerStrategy = count) }
                                }
                            },
                        )
                    }
                }

                Spacer(modifier = Modifier.height(14.dp))
                HorizontalDivider(color = glass.glassBorderBottom)
                Spacer(modifier = Modifier.height(8.dp))

                SettingSwitchRow(
                    title = "遇二维码过期立即中止",
                    subtitle = "服务端返回过期/失效时跳过剩余回退策略",
                    checked = uiState.settings.stopWhenTicketExpired,
                    enabled = !uiState.isSigning,
                    onCheckedChange = { checked ->
                        viewModel.updateSettings { it.copy(stopWhenTicketExpired = checked) }
                    },
                )
                SettingSwitchRow(
                    title = "演练模式（dryRun）",
                    subtitle = "零网络发包，仅生成策略链与请求轨迹供排障核对",
                    checked = uiState.settings.dryRun,
                    enabled = !uiState.isSigning,
                    onCheckedChange = { checked ->
                        viewModel.updateSettings { it.copy(dryRun = checked) }
                    },
                )
            }
        }

        // 4. 主执行 CTA
        item(key = "cta") {
            val canRun = uiState.ticket != null &&
                uiState.ticket.kind != TicketKind.LOGIN &&
                targets.isNotEmpty() &&
                !uiState.isSigning

            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                AuroraPrimaryButton(
                    text = when {
                        uiState.isSigning -> "正在并发执行签到…"
                        uiState.settings.dryRun -> "开始演练模拟（${targets.size} 个账号）"
                        else -> "立即并发签到（${targets.size} 个账号）"
                    },
                    icon = if (uiState.settings.dryRun) Icons.Rounded.Science else Icons.Rounded.PlayArrow,
                    enabled = canRun,
                    loading = uiState.isSigning,
                    onClick = viewModel::startSign,
                    modifier = Modifier.fillMaxWidth(),
                )
                Text(
                    text = "安全确认：扫码与粘贴默认只解析不自动提交，核对目标与域名后再触发。",
                    style = MaterialTheme.typography.bodySmall,
                    color = glass.inkMuted,
                    modifier = Modifier.padding(horizontal = 4.dp),
                )
            }
        }

        // 5. 实时执行日志
        if (uiState.liveLogs.isNotEmpty()) {
            item(key = "logs") {
                GlassCard {
                    SectionHeader(
                        title = "实时调度日志",
                        trailing = {
                            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                if (uiState.report != null) {
                                    GlassPill(
                                        text = "报文实验室",
                                        color = glass.accentTeal,
                                        icon = Icons.Rounded.Science,
                                        selected = true,
                                        onClick = { viewModel.selectTab(NavTab.RESULTS) },
                                    )
                                }
                                GlassPill(
                                    text = "清空",
                                    color = glass.inkMuted,
                                    icon = Icons.Rounded.DeleteSweep,
                                    onClick = viewModel::clearLogs,
                                )
                            }
                        },
                    )
                    Spacer(modifier = Modifier.height(10.dp))
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(14.dp))
                            .background(glass.codeSurface)
                            .padding(12.dp),
                        verticalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        uiState.liveLogs.takeLast(14).forEach { line ->
                            Text(
                                text = line,
                                style = MaterialTheme.typography.labelSmall.copy(fontFamily = FontFamily.Monospace),
                                color = glass.inkPrimary.copy(alpha = 0.88f),
                            )
                        }
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun QrHeroCard(
    ticket: QrTicket?,
    parsedAtMillis: Long?,
    domainWarning: String?,
    rawInput: String,
    isSigning: Boolean,
    onRawInputChange: (String) -> Unit,
    onParse: () -> Unit,
    onClear: () -> Unit,
    onOpenScanner: () -> Unit,
    onPaste: () -> Unit,
    onJumpQrLogin: () -> Unit,
) {
    val glass = RainCheckTheme.glass

    // 动态码实时每秒倒计时
    var nowMs by remember(ticket, parsedAtMillis) { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(ticket, parsedAtMillis) {
        if (ticket?.kind == TicketKind.DYNAMIC_CHECKIN) {
            while (true) {
                nowMs = System.currentTimeMillis()
                delay(1000L)
            }
        }
    }

    val heroAccent = when (ticket?.kind) {
        TicketKind.DYNAMIC_CHECKIN -> glass.accentTeal
        TicketKind.LESSON_ONLY -> glass.accentCyan
        TicketKind.LOGIN -> glass.statusAuth
        TicketKind.UNKNOWN -> glass.statusNeutral
        null -> null
    }

    GlassCard(accentColor = heroAccent, elevated = true) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Icon(
                    imageVector = Icons.Rounded.QrCode2,
                    contentDescription = null,
                    tint = heroAccent ?: glass.accentTeal,
                    modifier = Modifier.size(22.dp),
                )
                Text(
                    text = "二维码解析台",
                    style = MaterialTheme.typography.titleMedium,
                    color = glass.inkPrimary,
                )
            }
            if (ticket != null) {
                val kindLabel = when (ticket.kind) {
                    TicketKind.DYNAMIC_CHECKIN -> "动态签到码"
                    TicketKind.LESSON_ONLY -> "课堂静态码"
                    TicketKind.LOGIN -> "登录码（已拦截）"
                    TicketKind.UNKNOWN -> "未识别文本"
                }
                GlassPill(
                    text = kindLabel,
                    color = heroAccent ?: glass.statusNeutral,
                    selected = true,
                )
            }
        }

        Spacer(modifier = Modifier.height(12.dp))

        // 主扫码 + 粘贴操作栏
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            AuroraPrimaryButton(
                text = "CameraX 扫码",
                icon = Icons.Rounded.QrCodeScanner,
                enabled = !isSigning,
                onClick = onOpenScanner,
                modifier = Modifier.weight(1.35f),
            )
            GlassTonalButton(
                text = "粘贴解析",
                icon = Icons.Rounded.ContentPaste,
                enabled = !isSigning,
                onClick = onPaste,
                modifier = Modifier.weight(1f).height(52.dp),
            )
        }

        Spacer(modifier = Modifier.height(12.dp))

        // 手动输入与解析
        OutlinedTextField(
            value = rawInput,
            onValueChange = onRawInputChange,
            modifier = Modifier.fillMaxWidth(),
            enabled = !isSigning,
            label = { Text("二维码链接 / 参数串 / 课堂号") },
            placeholder = { Text("https://.../checkin?c=...&t=...&s=... 或 lessonId") },
            singleLine = false,
            maxLines = 3,
            shape = RoundedCornerShape(16.dp),
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
            keyboardActions = KeyboardActions(onDone = { onParse() }),
            trailingIcon = {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    if (rawInput.isNotEmpty()) {
                        IconButton(onClick = onClear) {
                            Icon(Icons.Rounded.Close, contentDescription = "清空", tint = glass.inkMuted)
                        }
                    }
                }
            },
            colors = OutlinedTextFieldDefaults.colors(
                focusedBorderColor = glass.accentTeal,
                unfocusedBorderColor = glass.glassBorderBottom,
                focusedTextColor = glass.inkPrimary,
                unfocusedTextColor = glass.inkPrimary,
            ),
        )

        if (rawInput.isNotBlank() && rawInput.trim() != ticket?.raw) {
            Spacer(modifier = Modifier.height(8.dp))
            GlassTonalButton(
                text = "解析当前输入",
                onClick = onParse,
                enabled = !isSigning,
                modifier = Modifier.fillMaxWidth(),
            )
        }

        // 解析结果详情区
        AnimatedVisibility(visible = ticket != null) {
            if (ticket != null) {
                Column(
                    modifier = Modifier.padding(top = 14.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    // 动态码实时倒计时进度条
                    if (ticket.kind == TicketKind.DYNAMIC_CHECKIN) {
                        val originMs = resolveDynamicOriginMs(ticket.timestamp, parsedAtMillis)
                        val elapsedSec = ((nowMs - originMs) / 1000L).coerceAtLeast(0L)
                        val windowSec = 15L
                        val remaining = (windowSec - elapsedSec).coerceAtLeast(0L)
                        val progress = (remaining.toFloat() / windowSec.toFloat()).coerceIn(0f, 1f)
                        val freshColor = when {
                            remaining >= 6 -> glass.statusSuccess
                            remaining > 0 -> glass.statusAuth
                            else -> glass.statusFailed
                        }
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(14.dp))
                                .background(freshColor.copy(alpha = if (glass.isDark) 0.14f else 0.08f))
                                .border(1.dp, freshColor.copy(alpha = 0.30f), RoundedCornerShape(14.dp))
                                .padding(horizontal = 12.dp, vertical = 10.dp),
                            verticalArrangement = Arrangement.spacedBy(6.dp),
                        ) {
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                                ) {
                                    Icon(
                                        imageVector = Icons.Rounded.Timer,
                                        contentDescription = null,
                                        tint = freshColor,
                                        modifier = Modifier.size(16.dp),
                                    )
                                    Text(
                                        text = if (remaining > 0) {
                                            "动态码时效窗口：剩余 ${remaining}s（已过 ${elapsedSec}s）"
                                        } else {
                                            "已过 ${elapsedSec}s，动态码可能已轮换，建议重扫"
                                        },
                                        style = MaterialTheme.typography.labelMedium,
                                        color = freshColor,
                                    )
                                }
                            }
                            LinearProgressIndicator(
                                progress = { progress },
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .height(5.dp)
                                    .clip(RoundedCornerShape(99.dp)),
                                color = freshColor,
                                trackColor = freshColor.copy(alpha = 0.18f),
                            )
                        }
                    }

                    // 登录码拦截横幅
                    if (ticket.kind == TicketKind.LOGIN) {
                        GlassBanner(
                            title = "已拦截登录二维码",
                            message = "这是雨课堂登录码而非课堂签到码，不能用于并发签到。",
                            accentColor = glass.statusAuth,
                            icon = Icons.Rounded.GppBad,
                            actionLabel = "去账号舱扫码登录",
                            onAction = onJumpQrLogin,
                        )
                    }

                    // 非白名单域名警告
                    if (domainWarning != null) {
                        GlassBanner(
                            title = "非白名单域名安全提醒",
                            message = domainWarning,
                            accentColor = glass.statusFailed,
                            icon = Icons.Rounded.Shield,
                        )
                    }

                    // 参数徽章流
                    FlowRow(
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                        verticalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        ticket.host?.let {
                            GlassPill(text = "host=$it", color = glass.accentCyan)
                        }
                        ticket.lessonId?.let {
                            GlassPill(text = "lessonId=$it", color = glass.accentTeal, selected = true)
                        }
                        ticket.classroomId?.let {
                            GlassPill(text = "classroom=$it", color = glass.accentIndigo)
                        }
                        ticket.dynamicCode?.let {
                            GlassPill(text = "c=${it.take(10)}${if (it.length > 10) "…" else ""}", color = glass.statusSuccess)
                        }
                        ticket.timestamp?.let {
                            GlassPill(text = "t=$it", color = glass.accentCyan)
                        }
                        ticket.signature?.let {
                            GlassPill(text = "s=${it.take(8)}${if (it.length > 8) "…" else ""}", color = glass.accentIndigo)
                        }
                        ticket.version?.let {
                            GlassPill(text = "v=$it", color = glass.statusNeutral)
                        }
                    }

                    Text(
                        text = ticket.raw,
                        style = MaterialTheme.typography.labelSmall,
                        color = glass.inkMuted,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
    }
}

@Composable
private fun SettingSwitchRow(
    title: String,
    subtitle: String,
    checked: Boolean,
    enabled: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    val glass = RainCheckTheme.glass
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 6.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(
            modifier = Modifier.weight(1f).padding(end = 12.dp),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Text(
                text = title,
                style = MaterialTheme.typography.titleSmall,
                color = glass.inkPrimary,
            )
            Text(
                text = subtitle,
                style = MaterialTheme.typography.bodySmall,
                color = glass.inkSecondary,
            )
        }
        Switch(
            checked = checked,
            enabled = enabled,
            onCheckedChange = onCheckedChange,
        )
    }
}

private fun resolveDynamicOriginMs(timestampParam: String?, parsedAtMillis: Long?): Long {
    val now = System.currentTimeMillis()
    val raw = timestampParam?.toLongOrNull()
    if (raw != null) {
        val candidate = when {
            raw in 1_600_000_000L..2_600_000_000L -> raw * 1000L
            raw in 1_600_000_000_000L..2_600_000_000_000L -> raw
            else -> null
        }
        if (candidate != null && kotlin.math.abs(now - candidate) < 600_000L) {
            return candidate
        }
    }
    return parsedAtMillis ?: now
}
