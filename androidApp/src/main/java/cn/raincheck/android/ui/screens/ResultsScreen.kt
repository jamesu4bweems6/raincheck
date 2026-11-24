package cn.raincheck.android.ui.screens

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ContentCopy
import androidx.compose.material.icons.rounded.ExpandLess
import androidx.compose.material.icons.rounded.ExpandMore
import androidx.compose.material.icons.rounded.IosShare
import androidx.compose.material.icons.rounded.QrCodeScanner
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import cn.raincheck.android.data.ReportExporter
import cn.raincheck.android.ui.components.AuroraPrimaryButton
import cn.raincheck.android.ui.components.GlassCard
import cn.raincheck.android.ui.components.GlassPill
import cn.raincheck.android.ui.components.GlassTonalButton
import cn.raincheck.android.ui.theme.GlassPalette
import cn.raincheck.android.ui.theme.RainCheckTheme
import cn.raincheck.android.viewmodel.NavTab
import cn.raincheck.android.viewmodel.RainCheckUiState
import cn.raincheck.android.viewmodel.RainCheckViewModel
import cn.raincheck.android.viewmodel.ResultFilter
import cn.raincheck.core.SignResult
import cn.raincheck.core.SignState
import cn.raincheck.core.StrategyAttempt

@Composable
fun ResultsScreen(
    uiState: RainCheckUiState,
    viewModel: RainCheckViewModel,
    onCopiedNotice: () -> Unit,
) {
    val glass = RainCheckTheme.glass
    val report = uiState.report
    val allResults = report?.results.orEmpty()

    val counts = remember(allResults) {
        ResultCounts(
            total = allResults.size,
            success = allResults.count { it.state == SignState.SUCCESS },
            already = allResults.count { it.state == SignState.ALREADY },
            dryRun = allResults.count { it.state == SignState.DRY_RUN },
            auth = allResults.count { it.state == SignState.AUTH_REQUIRED },
            expired = allResults.count { it.state == SignState.TICKET_EXPIRED },
            noContext = allResults.count { it.state == SignState.NO_CONTEXT },
            failed = allResults.count { it.state == SignState.FAILED },
            error = allResults.count { it.state == SignState.ERROR },
        )
    }

    val filtered = remember(allResults, uiState.resultFilter) {
        when (uiState.resultFilter) {
            ResultFilter.ALL -> allResults
            ResultFilter.SUCCESS -> allResults.filter { it.state == SignState.SUCCESS }
            ResultFilter.ALREADY -> allResults.filter { it.state == SignState.ALREADY }
            ResultFilter.DRY_RUN -> allResults.filter { it.state == SignState.DRY_RUN }
            ResultFilter.AUTH_REQUIRED -> allResults.filter { it.state == SignState.AUTH_REQUIRED }
            ResultFilter.TICKET_EXPIRED -> allResults.filter { it.state == SignState.TICKET_EXPIRED }
            ResultFilter.NO_CONTEXT -> allResults.filter { it.state == SignState.NO_CONTEXT }
            ResultFilter.FAILED -> allResults.filter { it.state == SignState.FAILED }
            ResultFilter.ERROR -> allResults.filter { it.state == SignState.ERROR }
        }
    }

    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .statusBarsPadding(),
        contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 16.dp, bottom = 112.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        item(key = "header") {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(
                        text = "报文实验室",
                        style = MaterialTheme.typography.headlineLarge,
                        color = glass.inkPrimary,
                    )
                    Text(
                        text = "策略轨迹回溯 · 脱敏报告安全分享",
                        style = MaterialTheme.typography.bodySmall,
                        color = glass.inkSecondary,
                    )
                }
                if (report != null) {
                    GlassPill(
                        text = "${report.elapsedMs} ms",
                        color = glass.accentCyan,
                    )
                }
            }
        }

        if (report == null || allResults.isEmpty()) {
            item(key = "empty") {
                GlassCard(elevated = true) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 22.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        Text(
                            text = "还没有签到批次报文",
                            style = MaterialTheme.typography.titleMedium,
                            color = glass.inkPrimary,
                        )
                        Text(
                            text = "在「签到台」扫描二维码并执行并发签到或演练后，这里会完整展示每个账号的策略尝试、HTTP 状态、业务码与响应报文。",
                            style = MaterialTheme.typography.bodySmall,
                            color = glass.inkSecondary,
                        )
                        AuroraPrimaryButton(
                            text = "前往签到台",
                            icon = Icons.Rounded.QrCodeScanner,
                            onClick = { viewModel.selectTab(NavTab.SIGN) },
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                }
            }
        } else {
            // 批次摘要与操作（重试严格绑定 report.ticket + FileProvider 安全分享）
            item(key = "summary") {
                GlassCard(elevated = true) {
                    Text(
                        text = "绑定二维码：${report.ticket.summary()}",
                        style = MaterialTheme.typography.titleSmall,
                        color = glass.inkPrimary,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Spacer(modifier = Modifier.height(4.dp))
                    Text(
                        text = buildString {
                            append("总计 ${allResults.size} 账号")
                            if (report.dryRunCount > 0) append(" · 演练 ${report.dryRunCount}")
                            append(" · 成功 ${report.successCount} · 失败 ${report.failedCount} · 总耗时 ${report.elapsedMs} ms")
                        },
                        style = MaterialTheme.typography.bodySmall,
                        color = glass.inkSecondary,
                    )
                    Spacer(modifier = Modifier.height(12.dp))
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        GlassTonalButton(
                            text = if (uiState.isRetrying) "重试中…" else "重试失败项 (${report.failedCount})",
                            icon = Icons.Rounded.Refresh,
                            accentColor = glass.statusAuth,
                            enabled = report.failedCount > 0 && !uiState.isRetrying && !uiState.isSigning,
                            onClick = viewModel::retryFailed,
                            modifier = Modifier.weight(1.1f),
                        )
                        GlassTonalButton(
                            text = "安全导出分享",
                            icon = Icons.Rounded.IosShare,
                            accentColor = glass.accentTeal,
                            enabled = allResults.isNotEmpty(),
                            onClick = viewModel::exportAndShareReport,
                            modifier = Modifier.weight(1f),
                        )
                    }
                }
            }

            // 状态统计与筛选胶囊流
            item(key = "filter-strip") {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    FilterChipItem("全部 ${counts.total}", ResultFilter.ALL, glass.accentTeal, uiState.resultFilter, viewModel::setResultFilter)
                    if (counts.success > 0) {
                        FilterChipItem("成功 ${counts.success}", ResultFilter.SUCCESS, glass.statusSuccess, uiState.resultFilter, viewModel::setResultFilter)
                    }
                    if (counts.already > 0) {
                        FilterChipItem("已签到 ${counts.already}", ResultFilter.ALREADY, glass.statusAlready, uiState.resultFilter, viewModel::setResultFilter)
                    }
                    if (counts.dryRun > 0) {
                        FilterChipItem("演练 ${counts.dryRun}", ResultFilter.DRY_RUN, glass.statusDryRun, uiState.resultFilter, viewModel::setResultFilter)
                    }
                    if (counts.auth > 0) {
                        FilterChipItem("需重登 ${counts.auth}", ResultFilter.AUTH_REQUIRED, glass.statusAuth, uiState.resultFilter, viewModel::setResultFilter)
                    }
                    if (counts.expired > 0) {
                        FilterChipItem("已过期 ${counts.expired}", ResultFilter.TICKET_EXPIRED, glass.statusExpired, uiState.resultFilter, viewModel::setResultFilter)
                    }
                    if (counts.noContext > 0) {
                        FilterChipItem("缺上下文 ${counts.noContext}", ResultFilter.NO_CONTEXT, glass.statusNeutral, uiState.resultFilter, viewModel::setResultFilter)
                    }
                    if (counts.failed > 0) {
                        FilterChipItem("失败 ${counts.failed}", ResultFilter.FAILED, glass.statusFailed, uiState.resultFilter, viewModel::setResultFilter)
                    }
                    if (counts.error > 0) {
                        FilterChipItem("异常 ${counts.error}", ResultFilter.ERROR, glass.statusFailed, uiState.resultFilter, viewModel::setResultFilter)
                    }
                }
            }

            if (filtered.isEmpty()) {
                item(key = "filtered-empty") {
                    GlassCard {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(
                                text = "当前筛选状态下暂无账号记录",
                                style = MaterialTheme.typography.bodySmall,
                                color = glass.inkSecondary,
                            )
                            GlassPill(
                                text = "查看全部",
                                color = glass.accentTeal,
                                selected = true,
                                onClick = { viewModel.setResultFilter(ResultFilter.ALL) },
                            )
                        }
                    }
                }
            } else {
                items(filtered, key = { it.accountId }) { result ->
                    val expanded = result.accountId in uiState.expandedAccountIds
                    ResultPacketCard(
                        result = result,
                        expanded = expanded,
                        onToggleExpand = { viewModel.toggleResultExpanded(result.accountId) },
                        onCopied = onCopiedNotice,
                    )
                }
            }
        }
    }
}

@Composable
private fun FilterChipItem(
    text: String,
    filter: ResultFilter,
    color: Color,
    current: ResultFilter,
    onSelect: (ResultFilter) -> Unit,
) {
    GlassPill(
        text = text,
        color = color,
        selected = current == filter,
        showDot = true,
        onClick = { onSelect(filter) },
    )
}

@Composable
private fun ResultPacketCard(
    result: SignResult,
    expanded: Boolean,
    onToggleExpand: () -> Unit,
    onCopied: () -> Unit,
) {
    val glass = RainCheckTheme.glass
    val clipboard = LocalClipboardManager.current
    val stateColor = colorForState(result.state, glass)
    val stateLabel = labelForState(result.state)
    val totalMs = remember(result.attempts) { result.attempts.sumOf { it.elapsedMs } }

    GlassCard(
        accentColor = stateColor,
        onClick = onToggleExpand,
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(3.dp),
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text(
                        text = result.label,
                        style = MaterialTheme.typography.titleMedium,
                        color = glass.inkPrimary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    GlassPill(text = stateLabel, color = stateColor, selected = true)
                }
                Text(
                    text = result.message,
                    style = MaterialTheme.typography.bodySmall,
                    color = glass.inkSecondary,
                    maxLines = if (expanded) 4 else 2,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    text = buildString {
                        append("策略 ${result.strategy ?: "-"}")
                        result.lessonId?.let { append(" · 课 $it") }
                        append(" · ${result.attempts.size} 次尝试 · ${totalMs} ms")
                    },
                    style = MaterialTheme.typography.labelSmall,
                    color = glass.inkMuted,
                )
            }
            Icon(
                imageVector = if (expanded) Icons.Rounded.ExpandLess else Icons.Rounded.ExpandMore,
                contentDescription = if (expanded) "收起明细" else "展开明细",
                tint = glass.inkSecondary,
                modifier = Modifier.size(22.dp),
            )
        }

        AnimatedVisibility(visible = expanded) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 12.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                HorizontalDivider(color = glass.glassBorderBottom)
                if (result.attempts.isEmpty()) {
                    Text(
                        text = "本次结果未产生网络策略尝试记录。",
                        style = MaterialTheme.typography.bodySmall,
                        color = glass.inkMuted,
                    )
                } else {
                    result.attempts.forEachIndexed { index, attempt ->
                        AttemptPacketBlock(
                            index = index + 1,
                            attempt = attempt,
                            onCopy = { block ->
                                clipboard.setText(AnnotatedString(block))
                                onCopied()
                            },
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun AttemptPacketBlock(
    index: Int,
    attempt: StrategyAttempt,
    onCopy: (String) -> Unit,
) {
    val glass = RainCheckTheme.glass
    val titleLine = "#$index ${attempt.strategy} · HTTP ${attempt.httpStatus ?: "-"} · code ${attempt.code ?: "-"} · ${attempt.elapsedMs} ms"
    val sanitizedReq = attempt.requestBody?.let { ReportExporter.sanitizeText(it, 600) }
    val sanitizedResp = attempt.responseBody?.let { ReportExporter.sanitizeText(it, 800) }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(glass.codeSurface)
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = titleLine,
                style = MaterialTheme.typography.labelSmall.copy(fontFamily = FontFamily.Monospace),
                color = if (attempt.ok) glass.statusSuccess else glass.accentCyan,
                modifier = Modifier.weight(1f),
            )
            GlassPill(
                text = "复制",
                color = glass.inkSecondary,
                icon = Icons.Rounded.ContentCopy,
                onClick = {
                    val block = buildString {
                        appendLine(titleLine)
                        if (attempt.requestLine.isNotBlank()) appendLine("REQ: ${ReportExporter.sanitizeText(attempt.requestLine, 500)}")
                        sanitizedReq?.let { appendLine("BODY: $it") }
                        sanitizedResp?.let { appendLine("RESP: $it") }
                        attempt.message?.let { appendLine("MSG: ${ReportExporter.sanitizeText(it, 400)}") }
                    }.trim()
                    onCopy(block)
                },
            )
        }
        if (attempt.requestLine.isNotBlank()) {
            Text(
                text = "REQ: ${ReportExporter.sanitizeText(attempt.requestLine, 300)}",
                style = MaterialTheme.typography.labelSmall.copy(fontFamily = FontFamily.Monospace),
                color = glass.inkPrimary.copy(alpha = 0.90f),
            )
        }
        if (!sanitizedReq.isNullOrBlank()) {
            Text(
                text = "BODY: $sanitizedReq",
                style = MaterialTheme.typography.labelSmall.copy(fontFamily = FontFamily.Monospace),
                color = glass.inkSecondary,
            )
        }
        if (!sanitizedResp.isNullOrBlank()) {
            Text(
                text = "RESP: $sanitizedResp",
                style = MaterialTheme.typography.labelSmall.copy(fontFamily = FontFamily.Monospace),
                color = glass.inkSecondary,
            )
        }
        if (!attempt.message.isNullOrBlank()) {
            Text(
                text = "MSG: ${ReportExporter.sanitizeText(attempt.message!!, 300)}",
                style = MaterialTheme.typography.labelSmall.copy(fontFamily = FontFamily.Monospace),
                color = glass.inkPrimary.copy(alpha = 0.85f),
            )
        }
    }
}

private data class ResultCounts(
    val total: Int,
    val success: Int,
    val already: Int,
    val dryRun: Int,
    val auth: Int,
    val expired: Int,
    val noContext: Int,
    val failed: Int,
    val error: Int,
)

private fun labelForState(state: SignState): String = when (state) {
    SignState.SUCCESS -> "成功"
    SignState.ALREADY -> "已签到"
    SignState.DRY_RUN -> "演练"
    SignState.AUTH_REQUIRED -> "需重登"
    SignState.TICKET_EXPIRED -> "已过期"
    SignState.NO_CONTEXT -> "缺上下文"
    SignState.FAILED -> "失败"
    SignState.ERROR -> "异常"
}

private fun colorForState(state: SignState, glass: GlassPalette): Color = when (state) {
    SignState.SUCCESS -> glass.statusSuccess
    SignState.ALREADY -> glass.statusAlready
    SignState.DRY_RUN -> glass.statusDryRun
    SignState.AUTH_REQUIRED -> glass.statusAuth
    SignState.TICKET_EXPIRED -> glass.statusExpired
    SignState.NO_CONTEXT -> glass.statusNeutral
    SignState.FAILED -> glass.statusFailed
    SignState.ERROR -> glass.statusFailed
}
