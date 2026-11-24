package cn.raincheck.android.ui.screens

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
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
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import cn.raincheck.android.ui.components.AuroraPrimaryButton
import cn.raincheck.android.ui.components.GlassPill
import cn.raincheck.android.ui.components.GlassTonalButton
import cn.raincheck.android.ui.theme.RainCheckTheme
import cn.raincheck.android.ui.theme.campusAccentColor
import cn.raincheck.android.util.QrRender
import cn.raincheck.core.Account
import cn.raincheck.core.Edition
import cn.raincheck.core.LoginPoll
import cn.raincheck.core.LoginService
import cn.raincheck.core.LoginState
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * 微信扫码登录 BottomSheet：
 * - 在 [Dispatchers.Default] 后台线程异步渲染二维码位图（绝不阻塞主线程）；
 * - 使用 [LaunchedEffect] 受管协程轮询，关闭 Sheet 或切换站点自动取消（零轮询/postDelayed 泄漏）；
 * - 完整支持 `PENDING` / `SCANNED` / `NEED_CODE`（4 位验证码） / `AUTHORIZED` / `EXPIRED` / `ERROR`。
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun QrLoginSheet(
    editions: List<Edition>,
    defaultEdition: Edition,
    loginService: LoginService,
    onAuthorized: (Account) -> Unit,
    onDismiss: () -> Unit,
) {
    val glass = RainCheckTheme.glass
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()

    var selectedEdition by remember { mutableStateOf(defaultEdition) }
    var refreshNonce by remember { mutableIntStateOf(0) }

    var loadingQr by remember { mutableStateOf(true) }
    var qrBitmap by remember { mutableStateOf<Bitmap?>(null) }
    var loginToken by remember { mutableStateOf<String?>(null) }
    var loginState by remember { mutableStateOf(LoginState.PENDING) }
    var statusText by remember { mutableStateOf("正在获取登录二维码…") }
    var codeInput by remember { mutableStateOf("") }
    var codeError by remember { mutableStateOf<String?>(null) }
    var submittingCode by remember { mutableStateOf(false) }

    // 受管扫码会话生命周期：随 Sheet 关闭或站点/刷新键变化自动取消
    LaunchedEffect(selectedEdition.id, refreshNonce) {
        loadingQr = true
        qrBitmap = null
        loginToken = null
        loginState = LoginState.PENDING
        statusText = "正在从 ${selectedEdition.host} 获取登录二维码…"
        codeInput = ""
        codeError = null
        submittingCode = false

        val started = try {
            withContext(Dispatchers.IO) { loginService.start(selectedEdition) }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            LoginPoll(LoginState.ERROR, e.message ?: "网络请求失败")
        }

        if (started.state != LoginState.PENDING || started.qrContent.isNullOrBlank() || started.loginToken.isNullOrBlank()) {
            loadingQr = false
            loginState = if (started.state == LoginState.EXPIRED) LoginState.EXPIRED else LoginState.ERROR
            statusText = started.message.ifBlank { "获取登录二维码失败" }
            return@LaunchedEffect
        }

        // 在 Dispatchers.Default 异步渲染位图，绝不卡主线程
        val bitmap = try {
            QrRender.bitmapAsync(started.qrContent!!, sizePx = 720)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            loadingQr = false
            loginState = LoginState.ERROR
            statusText = "二维码渲染失败：${e.message ?: e.javaClass.simpleName}"
            return@LaunchedEffect
        }

        val token = started.loginToken!!
        qrBitmap = bitmap
        loginToken = token
        loadingQr = false
        statusText = "请用该账号的微信扫描上方二维码"

        var polls = 0
        while (isActive) {
            delay(2_000L)
            polls++
            if (polls > 90) {
                loginState = LoginState.EXPIRED
                statusText = "二维码已超时，请点击刷新重试"
                return@LaunchedEffect
            }

            val poll = try {
                withContext(Dispatchers.IO) { loginService.poll(selectedEdition, token) }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                LoginPoll(LoginState.ERROR, e.message ?: "轮询失败")
            }

            when (poll.state) {
                LoginState.PENDING -> {
                    loginState = LoginState.PENDING
                    if (poll.message.isNotBlank()) statusText = poll.message
                }
                LoginState.SCANNED -> {
                    loginState = LoginState.SCANNED
                    statusText = poll.message.ifBlank { "已扫码，请在手机微信上点击确认" }
                }
                LoginState.NEED_CODE -> {
                    poll.loginToken?.let { loginToken = it }
                    loginState = LoginState.NEED_CODE
                    statusText = poll.message.ifBlank { "扫码成功，请输入微信显示的 4 位验证码" }
                    return@LaunchedEffect
                }
                LoginState.AUTHORIZED -> {
                    val account = poll.account
                    if (account == null || !account.hasCredential) {
                        loginState = LoginState.ERROR
                        statusText = "登录完成但未获取到有效会话凭据，请刷新重试"
                        return@LaunchedEffect
                    }
                    loginState = LoginState.AUTHORIZED
                    statusText = "登录成功：${account.label}"
                    onAuthorized(account)
                    delay(700L)
                    onDismiss()
                    return@LaunchedEffect
                }
                LoginState.EXPIRED -> {
                    loginState = LoginState.EXPIRED
                    statusText = poll.message.ifBlank { "二维码已失效，请刷新后重试" }
                    return@LaunchedEffect
                }
                LoginState.ERROR -> {
                    loginState = LoginState.ERROR
                    statusText = poll.message.ifBlank { "登录异常，请重试" }
                    return@LaunchedEffect
                }
            }
        }
    }

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
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text(
                text = "微信扫码登录",
                style = MaterialTheme.typography.headlineSmall,
                color = glass.inkPrimary,
                modifier = Modifier.fillMaxWidth(),
            )

            // 站点切换胶囊
            FlowRow(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                editions.forEach { edition ->
                    GlassPill(
                        text = edition.label,
                        color = campusAccentColor(edition.host, glass.isDark),
                        selected = edition.id == selectedEdition.id,
                        onClick = {
                            if (edition.id != selectedEdition.id) {
                                selectedEdition = edition
                            }
                        },
                    )
                }
            }

            // 二维码高对比度白底画布（深色主题下绝不反色）
            Box(
                modifier = Modifier
                    .size(236.dp)
                    .clip(RoundedCornerShape(24.dp))
                    .background(Color.White)
                    .border(2.dp, glass.accentTeal.copy(alpha = 0.45f), RoundedCornerShape(24.dp)),
                contentAlignment = Alignment.Center,
            ) {
                when {
                    loadingQr -> {
                        CircularProgressIndicator(color = glass.accentTeal)
                    }
                    loginState == LoginState.AUTHORIZED -> {
                        Icon(
                            imageVector = Icons.Rounded.CheckCircle,
                            contentDescription = "登录成功",
                            tint = glass.statusSuccess,
                            modifier = Modifier.size(72.dp),
                        )
                    }
                    qrBitmap != null -> {
                        Image(
                            bitmap = qrBitmap!!.asImageBitmap(),
                            contentDescription = "微信登录二维码",
                            modifier = Modifier
                                .size(212.dp)
                                .clip(RoundedCornerShape(14.dp)),
                        )
                    }
                    else -> {
                        Text(
                            text = "二维码不可用",
                            style = MaterialTheme.typography.bodySmall,
                            color = Color(0xFF475569),
                        )
                    }
                }
            }

            val statusColor = when (loginState) {
                LoginState.AUTHORIZED -> glass.statusSuccess
                LoginState.SCANNED -> glass.accentTeal
                LoginState.NEED_CODE -> glass.accentIndigo
                LoginState.EXPIRED -> glass.statusExpired
                LoginState.ERROR -> glass.statusFailed
                LoginState.PENDING -> glass.inkSecondary
            }
            Text(
                text = statusText,
                style = MaterialTheme.typography.bodyMedium,
                color = statusColor,
                textAlign = TextAlign.Center,
            )

            // 4 位验证码输入框
            if (loginState == LoginState.NEED_CODE) {
                Column(
                    modifier = Modifier.fillMaxWidth(),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    OutlinedTextField(
                        value = codeInput,
                        onValueChange = { raw ->
                            codeInput = raw.filter { it.isDigit() }.take(4)
                            codeError = null
                        },
                        label = { Text("输入 4 位数字验证码") },
                        singleLine = true,
                        isError = codeError != null,
                        supportingText = codeError?.let { msg -> { Text(msg) } },
                        shape = RoundedCornerShape(16.dp),
                        keyboardOptions = KeyboardOptions(
                            autoCorrectEnabled = false,
                            keyboardType = KeyboardType.NumberPassword,
                            imeAction = ImeAction.Done,
                        ),
                        modifier = Modifier.fillMaxWidth(),
                    )
                    AuroraPrimaryButton(
                        text = if (submittingCode) "正在验证…" else "提交 4 位验证码",
                        enabled = codeInput.length == 4 && !submittingCode,
                        loading = submittingCode,
                        onClick = {
                            val token = loginToken
                            if (token == null) {
                                loginState = LoginState.EXPIRED
                                statusText = "登录令牌已过期，请刷新二维码"
                                return@AuroraPrimaryButton
                            }
                            if (codeInput.length != 4 || codeInput.any { !it.isDigit() }) {
                                codeError = "验证码必须是 4 位数字"
                                return@AuroraPrimaryButton
                            }
                            submittingCode = true
                            val targetEdition = selectedEdition
                            val submittedCode = codeInput
                            scope.launch {
                                val res = try {
                                    withContext(Dispatchers.IO) {
                                        loginService.submitCode(targetEdition, token, submittedCode)
                                    }
                                } catch (e: CancellationException) {
                                    throw e
                                } catch (e: Throwable) {
                                    LoginPoll(LoginState.ERROR, e.message ?: "提交验证码失败")
                                } finally {
                                    submittingCode = false
                                }

                                when (res.state) {
                                    LoginState.AUTHORIZED -> {
                                        val acc = res.account
                                        if (acc == null || !acc.hasCredential) {
                                            loginState = LoginState.ERROR
                                            statusText = "验证通过但未收到会话凭据"
                                        } else {
                                            loginState = LoginState.AUTHORIZED
                                            statusText = "登录成功：${acc.label}"
                                            onAuthorized(acc)
                                            delay(700L)
                                            onDismiss()
                                        }
                                    }
                                    LoginState.EXPIRED -> {
                                        loginState = LoginState.EXPIRED
                                        statusText = res.message.ifBlank { "验证码或二维码已失效" }
                                    }
                                    LoginState.ERROR -> {
                                        loginState = LoginState.ERROR
                                        statusText = res.message.ifBlank { "提交验证码失败" }
                                    }
                                    else -> {
                                        res.loginToken?.let { loginToken = it }
                                        codeError = res.message.ifBlank { "验证码未通过，请重新输入" }
                                        codeInput = ""
                                    }
                                }
                            }
                        },
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                GlassTonalButton(
                    text = "关闭",
                    accentColor = glass.inkSecondary,
                    onClick = onDismiss,
                    modifier = Modifier.weight(1f).height(48.dp),
                )
                GlassTonalButton(
                    text = "刷新二维码",
                    icon = Icons.Rounded.Refresh,
                    accentColor = glass.accentTeal,
                    onClick = { refreshNonce++ },
                    modifier = Modifier.weight(1.3f).height(48.dp),
                )
            }
            Spacer(modifier = Modifier.height(8.dp))
        }
    }
}
