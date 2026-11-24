package cn.raincheck.android.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Visibility
import androidx.compose.material.icons.rounded.VisibilityOff
import androidx.compose.material.icons.rounded.WarningAmber
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import cn.raincheck.android.ui.components.AuroraPrimaryButton
import cn.raincheck.android.ui.components.GlassBanner
import cn.raincheck.android.ui.components.GlassPill
import cn.raincheck.android.ui.components.GlassTonalButton
import cn.raincheck.android.ui.theme.RainCheckTheme
import cn.raincheck.android.ui.theme.campusAccentColor
import cn.raincheck.android.viewmodel.RainCheckViewModel
import cn.raincheck.core.Edition

private enum class CarrierMode(val label: String) {
    BEARER("Bearer Token"),
    COOKIE("Cookie 会话"),
    BOTH("双载体"),
}

/**
 * 手动添加账号 BottomSheet：
 * - 支持全部预设站点（含荷塘雨课堂 `pro.yuketang.cn`、学堂在线、本地演练）及自定义 Host/Scheme；
 * - 自动剥离 `Bearer ` 前缀；
 * - 凭据输入框显式关闭输入法自动纠错与词库学习（`autoCorrectEnabled = false` + `KeyboardType.Password` + 显隐切换）；
 * - 严格拦截空标签、非法 Host 与空凭据。
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun AddAccountSheet(
    editions: List<Edition>,
    defaultEdition: Edition,
    onDismiss: () -> Unit,
    onSave: (
        label: String,
        host: String,
        scheme: String,
        bearer: String?,
        sessionId: String?,
        csrfToken: String?,
        note: String,
    ) -> Unit,
) {
    val glass = RainCheckTheme.glass
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    var label by remember { mutableStateOf("") }
    var useCustomSite by remember { mutableStateOf(false) }
    var selectedEdition by remember { mutableStateOf(defaultEdition) }
    var customScheme by remember { mutableStateOf("https") }
    var customHost by remember { mutableStateOf("") }

    var carrierMode by remember { mutableStateOf(CarrierMode.BEARER) }
    var bearerInput by remember { mutableStateOf("") }
    var sessionInput by remember { mutableStateOf("") }
    var csrfInput by remember { mutableStateOf("") }

    var revealBearer by remember { mutableStateOf(false) }
    var revealSession by remember { mutableStateOf(false) }
    var revealCsrf by remember { mutableStateOf(false) }

    var errorText by remember { mutableStateOf<String?>(null) }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = if (glass.isDark) glass.bgMid else glass.bgTop,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .imePadding()
                .navigationBarsPadding()
                .padding(horizontal = 20.dp, vertical = 6.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text(
                text = "手动添加账号",
                style = MaterialTheme.typography.headlineSmall,
                color = glass.inkPrimary,
            )

            OutlinedTextField(
                value = label,
                onValueChange = {
                    label = it
                    errorText = null
                },
                label = { Text("账号标签（必填）") },
                placeholder = { Text("例如：本机微信 / 荷塘主号") },
                singleLine = true,
                shape = RoundedCornerShape(16.dp),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Next),
                modifier = Modifier.fillMaxWidth(),
            )

            // 站点选择（预设 + 自定义 Host/Scheme）
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    text = "选择站点",
                    style = MaterialTheme.typography.titleSmall,
                    color = glass.inkPrimary,
                )
                FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    editions.forEach { edition ->
                        val picked = !useCustomSite && selectedEdition.id == edition.id
                        GlassPill(
                            text = "${edition.label} (${edition.host})",
                            color = campusAccentColor(edition.host, glass.isDark),
                            selected = picked,
                            onClick = {
                                useCustomSite = false
                                selectedEdition = edition
                                errorText = null
                            },
                        )
                    }
                    GlassPill(
                        text = "自定义站点",
                        color = glass.accentIndigo,
                        selected = useCustomSite,
                        onClick = {
                            useCustomSite = true
                            errorText = null
                        },
                    )
                }
            }

            if (useCustomSite) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        listOf("https", "http").forEach { scheme ->
                            GlassPill(
                                text = scheme.uppercase(),
                                color = if (scheme == "https") glass.statusSuccess else glass.statusAuth,
                                selected = customScheme == scheme,
                                onClick = { customScheme = scheme },
                            )
                        }
                    }
                    OutlinedTextField(
                        value = customHost,
                        onValueChange = {
                            customHost = it
                            errorText = null
                        },
                        label = { Text("自定义域名 / Host（支持端口）") },
                        placeholder = { Text("例如：pro.yuketang.cn 或 127.0.0.1:8787") },
                        singleLine = true,
                        shape = RoundedCornerShape(16.dp),
                        keyboardOptions = KeyboardOptions(
                            autoCorrectEnabled = false,
                            keyboardType = KeyboardType.Uri,
                            imeAction = ImeAction.Next,
                        ),
                        modifier = Modifier.fillMaxWidth(),
                    )
                    val hostNoPort = sanitizeHost(customHost).substringBefore(':').lowercase()
                    if (customScheme == "http" && hostNoPort.isNotEmpty() &&
                        hostNoPort != "127.0.0.1" && hostNoPort != "localhost"
                    ) {
                        GlassBanner(
                            title = "明文 HTTP 受网络安全配置拦截",
                            message = "Android 仅放行 127.0.0.1 / localhost 的明文 HTTP，公网或校内站点请使用 HTTPS。",
                            accentColor = glass.statusAuth,
                            icon = Icons.Rounded.WarningAmber,
                        )
                    }
                }
            }

            // 凭据载体选择
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    text = "凭据载体（输入框已禁用输入法学习与自动更正）",
                    style = MaterialTheme.typography.titleSmall,
                    color = glass.inkPrimary,
                )
                FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    CarrierMode.entries.forEach { mode ->
                        GlassPill(
                            text = mode.label,
                            color = glass.accentTeal,
                            selected = carrierMode == mode,
                            onClick = {
                                carrierMode = mode
                                errorText = null
                            },
                        )
                    }
                }
            }

            if (carrierMode == CarrierMode.BEARER || carrierMode == CarrierMode.BOTH) {
                SecretCredentialField(
                    value = bearerInput,
                    onValueChange = {
                        bearerInput = it
                        errorText = null
                    },
                    label = "Bearer Token（自动剥离 Bearer 前缀）",
                    revealed = revealBearer,
                    onToggleReveal = { revealBearer = !revealBearer },
                )
            }

            if (carrierMode == CarrierMode.COOKIE || carrierMode == CarrierMode.BOTH) {
                SecretCredentialField(
                    value = sessionInput,
                    onValueChange = {
                        sessionInput = it
                        errorText = null
                    },
                    label = "Cookie: sessionid",
                    revealed = revealSession,
                    onToggleReveal = { revealSession = !revealSession },
                )
                SecretCredentialField(
                    value = csrfInput,
                    onValueChange = {
                        csrfInput = it
                        errorText = null
                    },
                    label = "Cookie: csrftoken（可选，推荐一并填写）",
                    revealed = revealCsrf,
                    onToggleReveal = { revealCsrf = !revealCsrf },
                    imeAction = ImeAction.Done,
                )
            }

            if (errorText != null) {
                Text(
                    text = errorText.orEmpty(),
                    style = MaterialTheme.typography.bodySmall,
                    color = glass.statusFailed,
                )
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                GlassTonalButton(
                    text = "取消",
                    accentColor = glass.inkSecondary,
                    onClick = onDismiss,
                    modifier = Modifier.weight(1f).height(52.dp),
                )
                AuroraPrimaryButton(
                    text = "加密保存",
                    onClick = {
                        val trimmedLabel = label.trim()
                        if (trimmedLabel.isEmpty()) {
                            errorText = "请填写账号标签"
                            return@AuroraPrimaryButton
                        }

                        val resolvedHost: String
                        val resolvedScheme: String
                        val resolvedNote: String
                        if (useCustomSite) {
                            val cleaned = sanitizeHost(customHost)
                            if (cleaned.isEmpty() || cleaned.any { it.isWhitespace() || it == '/' }) {
                                errorText = "请填写合法的自定义 Host（不含路径与空格）"
                                return@AuroraPrimaryButton
                            }
                            resolvedHost = cleaned
                            resolvedScheme = customScheme
                            resolvedNote = "自定义站点"
                        } else {
                            resolvedHost = selectedEdition.host
                            resolvedScheme = selectedEdition.scheme
                            resolvedNote = selectedEdition.label
                        }

                        val finalBearer = if (carrierMode == CarrierMode.BEARER || carrierMode == CarrierMode.BOTH) {
                            RainCheckViewModel.stripBearerPrefix(bearerInput)
                        } else {
                            null
                        }
                        val finalSession = if (carrierMode == CarrierMode.COOKIE || carrierMode == CarrierMode.BOTH) {
                            sessionInput.trim().takeIf { it.isNotEmpty() }
                        } else {
                            null
                        }
                        val finalCsrf = if (carrierMode == CarrierMode.COOKIE || carrierMode == CarrierMode.BOTH) {
                            csrfInput.trim().takeIf { it.isNotEmpty() }
                        } else {
                            null
                        }

                        if (finalBearer == null && finalSession == null) {
                            errorText = when (carrierMode) {
                                CarrierMode.BEARER -> "请填写有效的 Bearer Token（不能为空）"
                                CarrierMode.COOKIE -> "请填写有效的 sessionid（不能为空）"
                                CarrierMode.BOTH -> "请至少填写 Bearer Token 或 sessionid 之一"
                            }
                            return@AuroraPrimaryButton
                        }

                        onSave(
                            trimmedLabel,
                            resolvedHost,
                            resolvedScheme,
                            finalBearer,
                            finalSession,
                            finalCsrf,
                            resolvedNote,
                        )
                    },
                    modifier = Modifier.weight(1.4f),
                )
            }
            Spacer(modifier = Modifier.height(10.dp))
        }
    }
}

@Composable
private fun SecretCredentialField(
    value: String,
    onValueChange: (String) -> Unit,
    label: String,
    revealed: Boolean,
    onToggleReveal: () -> Unit,
    imeAction: ImeAction = ImeAction.Next,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        label = { Text(label) },
        singleLine = true,
        shape = RoundedCornerShape(16.dp),
        visualTransformation = if (revealed) VisualTransformation.None else PasswordVisualTransformation(),
        keyboardOptions = KeyboardOptions(
            autoCorrectEnabled = false,
            keyboardType = KeyboardType.Password,
            imeAction = imeAction,
        ),
        trailingIcon = {
            IconButton(onClick = onToggleReveal) {
                Icon(
                    imageVector = if (revealed) Icons.Rounded.VisibilityOff else Icons.Rounded.Visibility,
                    contentDescription = if (revealed) "隐藏凭据" else "显示凭据",
                )
            }
        },
        modifier = Modifier.fillMaxWidth(),
    )
}

private fun sanitizeHost(input: String): String {
    var s = input.trim()
    if (s.startsWith("https://", ignoreCase = true)) s = s.substring(8)
    else if (s.startsWith("http://", ignoreCase = true)) s = s.substring(7)
    return s.substringBefore('/').substringBefore('?').substringBefore('#').trim()
}
