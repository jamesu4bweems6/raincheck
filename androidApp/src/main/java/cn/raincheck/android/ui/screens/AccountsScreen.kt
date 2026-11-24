package cn.raincheck.android.ui.screens

import androidx.compose.foundation.background
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
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Cookie
import androidx.compose.material.icons.rounded.DeleteOutline
import androidx.compose.material.icons.rounded.ErrorOutline
import androidx.compose.material.icons.rounded.Key
import androidx.compose.material.icons.rounded.Lock
import androidx.compose.material.icons.rounded.QrCode2
import androidx.compose.material.icons.rounded.VerifiedUser
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import cn.raincheck.android.ui.components.AuroraPrimaryButton
import cn.raincheck.android.ui.components.GlassBanner
import cn.raincheck.android.ui.components.GlassCard
import cn.raincheck.android.ui.components.GlassPill
import cn.raincheck.android.ui.components.GlassTonalButton
import cn.raincheck.android.ui.theme.RainCheckTheme
import cn.raincheck.android.ui.theme.campusAccentColor
import cn.raincheck.android.viewmodel.RainCheckUiState
import cn.raincheck.android.viewmodel.RainCheckViewModel
import cn.raincheck.core.Account
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

@Composable
fun AccountsScreen(
    uiState: RainCheckUiState,
    viewModel: RainCheckViewModel,
) {
    val glass = RainCheckTheme.glass
    var pendingDelete by remember { mutableStateOf<Account?>(null) }

    val enabledCount = remember(uiState.accounts) { uiState.accounts.count { it.enabled } }
    val verifiedCount = remember(uiState.accounts) { uiState.accounts.count { it.lastOkAt != null } }

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
                        text = "账号舱",
                        style = MaterialTheme.typography.headlineLarge,
                        color = glass.inkPrimary,
                    )
                    Text(
                        text = "多校区双载体凭据 · 硬件密钥库加密保护",
                        style = MaterialTheme.typography.bodySmall,
                        color = glass.inkSecondary,
                    )
                }
                GlassPill(
                    text = "AES-GCM",
                    color = glass.statusSuccess,
                    icon = Icons.Rounded.Lock,
                )
            }
        }

        if (uiState.storageError != null) {
            item(key = "storage-error") {
                GlassBanner(
                    title = "加密存储读取异常",
                    message = uiState.storageError,
                    accentColor = glass.statusFailed,
                    icon = Icons.Rounded.ErrorOutline,
                    actionLabel = "知道了",
                    onAction = viewModel::dismissStorageError,
                )
            }
        }

        // 账号健康度总览毛玻璃条
        item(key = "health-bar") {
            GlassCard(elevated = true) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    HealthStatCell(label = "总账号", value = uiState.accounts.size.toString(), color = glass.inkPrimary)
                    HealthStatCell(label = "已启用", value = enabledCount.toString(), color = glass.accentTeal)
                    HealthStatCell(label = "已校验", value = verifiedCount.toString(), color = glass.statusSuccess)
                    GlassTonalButton(
                        text = "校验全部",
                        icon = Icons.Rounded.VerifiedUser,
                        enabled = uiState.accounts.isNotEmpty() && uiState.verifyingAccountIds.isEmpty(),
                        onClick = viewModel::verifyAllAccounts,
                    )
                }
            }
        }

        // 扫码登录 + 手动添加操作行
        item(key = "actions") {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                AuroraPrimaryButton(
                    text = "微信扫码登录",
                    icon = Icons.Rounded.QrCode2,
                    onClick = viewModel::openQrLoginSheet,
                    modifier = Modifier.weight(1.25f),
                )
                GlassTonalButton(
                    text = "手动添加",
                    icon = Icons.Rounded.Add,
                    onClick = viewModel::openAddAccountSheet,
                    modifier = Modifier.weight(1f).height(52.dp),
                )
            }
        }

        if (uiState.accounts.isEmpty()) {
            item(key = "empty") {
                GlassCard {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 18.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Text(
                            text = "账号舱为空",
                            style = MaterialTheme.typography.titleMedium,
                            color = glass.inkPrimary,
                        )
                        Text(
                            text = "点击「微信扫码登录」自动接入会话，或「手动添加」导入 Bearer / Cookie 凭据。全部凭据均经 AndroidKeyStore 加密存储。",
                            style = MaterialTheme.typography.bodySmall,
                            color = glass.inkSecondary,
                        )
                    }
                }
            }
        } else {
            items(uiState.accounts, key = { it.id }) { account ->
                AccountGlassCard(
                    account = account,
                    verifying = account.id in uiState.verifyingAccountIds,
                    onToggle = { enabled -> viewModel.toggleAccountEnabled(account, enabled) },
                    onVerify = { viewModel.verifyAccount(account) },
                    onDelete = { pendingDelete = account },
                )
            }
        }
    }

    pendingDelete?.let { target ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text("删除账号") },
            text = { Text("确定永久删除账号「${target.label}」（${target.host}）？此操作不可撤销。") },
            confirmButton = {
                TextButton(
                    onClick = {
                        viewModel.deleteAccount(target)
                        pendingDelete = null
                    },
                ) {
                    Text("删除", color = glass.statusFailed)
                }
            },
            dismissButton = {
                TextButton(onClick = { pendingDelete = null }) {
                    Text("取消")
                }
            },
        )
    }
}

@Composable
private fun HealthStatCell(
    label: String,
    value: String,
    color: Color,
) {
    val glass = RainCheckTheme.glass
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            text = value,
            style = MaterialTheme.typography.headlineSmall,
            color = color,
        )
        Text(
            text = label,
            style = MaterialTheme.typography.bodySmall,
            color = glass.inkSecondary,
        )
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun AccountGlassCard(
    account: Account,
    verifying: Boolean,
    onToggle: (Boolean) -> Unit,
    onVerify: () -> Unit,
    onDelete: () -> Unit,
) {
    val glass = RainCheckTheme.glass
    val campusColor = campusAccentColor(account.host, glass.isDark)

    GlassCard(
        accentColor = if (account.enabled) campusColor else null,
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            // 校区着色指示竖条
            Box(
                modifier = Modifier
                    .width(5.dp)
                    .height(44.dp)
                    .clip(RoundedCornerShape(99.dp))
                    .background(if (account.enabled) campusColor else glass.inkMuted.copy(alpha = 0.45f)),
            )
            Spacer(modifier = Modifier.width(12.dp))
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(3.dp),
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text(
                        text = account.label,
                        style = MaterialTheme.typography.titleMedium,
                        color = if (account.enabled) glass.inkPrimary else glass.inkSecondary,
                    )
                    if (!account.enabled) {
                        GlassPill(text = "已停用", color = glass.inkMuted)
                    }
                }
                Text(
                    text = buildString {
                        append("${account.scheme}://${account.host}")
                        if (!account.userId.isNullOrBlank()) append(" · UID ${account.userId}")
                    },
                    style = MaterialTheme.typography.bodySmall,
                    color = glass.inkSecondary,
                )
            }
            Switch(
                checked = account.enabled,
                onCheckedChange = onToggle,
            )
        }

        Spacer(modifier = Modifier.height(10.dp))

        // 同时展示 Bearer 与 Cookie 双载体标签（不再只展示 Bearer！）
        FlowRow(
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            GlassPill(
                text = account.note.ifBlank { account.host },
                color = campusColor,
            )
            val bearer = account.bearer?.takeIf { it.isNotBlank() }
            val session = account.sessionId?.takeIf { it.isNotBlank() }
            val csrf = account.csrfToken?.takeIf { it.isNotBlank() }

            if (bearer != null) {
                GlassPill(
                    text = "Bearer · ${maskSecret(bearer)}",
                    color = glass.accentTeal,
                    icon = Icons.Rounded.Key,
                )
            }
            if (session != null) {
                val cookieLabel = buildString {
                    append("Cookie · ${maskSecret(session)}")
                    if (csrf != null) append(" +CSRF")
                }
                GlassPill(
                    text = cookieLabel,
                    color = glass.accentIndigo,
                    icon = Icons.Rounded.Cookie,
                )
            }
            if (bearer == null && session == null) {
                GlassPill(
                    text = "未配置凭据",
                    color = glass.statusFailed,
                )
            }
        }

        Spacer(modifier = Modifier.height(10.dp))

        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = account.lastOkAt?.let { "最近有效：${formatTime(it)}" } ?: "尚未校验会话",
                style = MaterialTheme.typography.bodySmall,
                color = if (account.lastOkAt != null) glass.statusSuccess else glass.inkMuted,
            )
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                if (verifying) {
                    Box(
                        modifier = Modifier
                            .size(36.dp)
                            .clip(CircleShape),
                        contentAlignment = Alignment.Center,
                    ) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(18.dp),
                            strokeWidth = 2.dp,
                            color = glass.accentTeal,
                        )
                    }
                } else {
                    IconButton(onClick = onVerify, enabled = account.hasCredential) {
                        Icon(
                            imageVector = Icons.Rounded.VerifiedUser,
                            contentDescription = "校验会话",
                            tint = if (account.hasCredential) glass.accentTeal else glass.inkMuted,
                        )
                    }
                }
                IconButton(onClick = onDelete) {
                    Icon(
                        imageVector = Icons.Rounded.DeleteOutline,
                        contentDescription = "删除账号",
                        tint = glass.statusFailed.copy(alpha = 0.85f),
                    )
                }
            }
        }
    }
}

private fun maskSecret(raw: String): String = when {
    raw.length <= 12 -> "****"
    raw.length <= 20 -> raw.take(2) + "…" + raw.takeLast(2)
    else -> raw.take(4) + "…" + raw.takeLast(3)
}

private fun formatTime(epochMs: Long): String =
    SimpleDateFormat("MM-dd HH:mm", Locale.getDefault()).format(Date(epochMs))
