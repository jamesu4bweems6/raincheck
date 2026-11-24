package cn.raincheck.android

import android.graphics.Color
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.tween
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Groups
import androidx.compose.material.icons.rounded.QrCodeScanner
import androidx.compose.material.icons.rounded.Science
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import cn.raincheck.android.data.ReportExporter
import cn.raincheck.android.ui.components.AuroraGlassBackground
import cn.raincheck.android.ui.components.FloatingGlassNavBar
import cn.raincheck.android.ui.components.NavDestination
import cn.raincheck.android.ui.screens.AccountsScreen
import cn.raincheck.android.ui.screens.AddAccountSheet
import cn.raincheck.android.ui.screens.QrLoginSheet
import cn.raincheck.android.ui.screens.QrScannerScreen
import cn.raincheck.android.ui.screens.ResultsScreen
import cn.raincheck.android.ui.screens.SignScreen
import cn.raincheck.android.ui.theme.RainCheckTheme
import cn.raincheck.android.viewmodel.NavTab
import cn.raincheck.android.viewmodel.RainCheckViewModel
import kotlinx.coroutines.launch

/**
 * 单 Activity + 100% Jetpack Compose Material 3 入口。
 *
 * 彻底抛弃旧版 Fragment `hide/show` 架构，采用 Edge-to-Edge 全屏极光毛玻璃布局 +
 * `RainCheckViewModel` 单向数据流，从根源消除切页不刷新与后台 `FragmentTransaction.commit()` 闪退。
 */
class MainActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            val darkTheme = isSystemInDarkTheme()
            DisposableEffect(darkTheme) {
                enableEdgeToEdge(
                    statusBarStyle = SystemBarStyle.auto(
                        Color.TRANSPARENT,
                        Color.TRANSPARENT,
                    ) { darkTheme },
                    navigationBarStyle = SystemBarStyle.auto(
                        Color.TRANSPARENT,
                        Color.TRANSPARENT,
                    ) { darkTheme },
                )
                onDispose {}
            }

            RainCheckTheme(darkTheme = darkTheme) {
                RainCheckRoot()
            }
        }
    }
}

@Composable
private fun RainCheckRoot(
    viewModel: RainCheckViewModel = viewModel(),
) {
    val context = LocalContext.current
    val app = remember { RainCheckApp.get() }
    val uiState by viewModel.uiState.collectAsStateWithLifecycle()
    val snackbarHostState = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()

    // 统一消费一次性通知消息
    LaunchedEffect(uiState.notice?.id) {
        val notice = uiState.notice ?: return@LaunchedEffect
        snackbarHostState.showSnackbar(notice.message)
        viewModel.consumeNotice(notice.id)
    }

    // 触发 FileProvider 系统分享面板
    LaunchedEffect(uiState.pendingShareFile) {
        val file = uiState.pendingShareFile ?: return@LaunchedEffect
        viewModel.consumePendingShare()
        runCatching {
            context.startActivity(ReportExporter.createShareIntent(context, file))
        }.onFailure { err ->
            snackbarHostState.showSnackbar("无法拉起系统分享：${err.message ?: err.javaClass.simpleName}")
        }
    }

    AuroraGlassBackground {
        Box(modifier = Modifier.fillMaxSize()) {
            Crossfade(
                targetState = uiState.selectedTab,
                animationSpec = tween(durationMillis = 220),
                label = "tabCrossfade",
            ) { tab ->
                when (tab) {
                    NavTab.SIGN -> SignScreen(
                        uiState = uiState,
                        viewModel = viewModel,
                    )
                    NavTab.ACCOUNTS -> AccountsScreen(
                        uiState = uiState,
                        viewModel = viewModel,
                    )
                    NavTab.RESULTS -> ResultsScreen(
                        uiState = uiState,
                        viewModel = viewModel,
                        onCopiedNotice = {
                            scope.launch { snackbarHostState.showSnackbar("已复制脱敏报文到剪贴板") }
                        },
                    )
                }
            }

            // 悬浮胶囊底部导航栏（签到台 / 账号舱 / 报文实验室）
            val destinations = remember(uiState.report?.results?.size, uiState.isSigning, uiState.isRetrying) {
                listOf(
                    NavDestination(
                        key = NavTab.SIGN.key,
                        label = "签到台",
                        icon = Icons.Rounded.QrCodeScanner,
                        pulsing = uiState.isSigning,
                    ),
                    NavDestination(
                        key = NavTab.ACCOUNTS.key,
                        label = "账号舱",
                        icon = Icons.Rounded.Groups,
                    ),
                    NavDestination(
                        key = NavTab.RESULTS.key,
                        label = "报文实验室",
                        icon = Icons.Rounded.Science,
                        badgeCount = uiState.report?.results?.size ?: 0,
                        pulsing = uiState.isRetrying,
                    ),
                )
            }

            FloatingGlassNavBar(
                destinations = destinations,
                selectedKey = uiState.selectedTab.key,
                onSelect = { key ->
                    val next = NavTab.entries.firstOrNull { it.key == key } ?: NavTab.SIGN
                    viewModel.selectTab(next)
                },
                modifier = Modifier.align(Alignment.BottomCenter),
            )

            SnackbarHost(
                hostState = snackbarHostState,
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .navigationBarsPadding()
                    .padding(bottom = 84.dp, start = 16.dp, end = 16.dp),
            )

            // CameraX 全屏扫码覆盖层
            if (uiState.showScanner) {
                QrScannerScreen(
                    onScanned = viewModel::onQrScanned,
                    onClose = viewModel::closeScanner,
                )
            }
        }
    }

    // 手动添加账号 BottomSheet
    if (uiState.showAddAccountSheet) {
        AddAccountSheet(
            editions = viewModel.editions,
            defaultEdition = viewModel.defaultEdition,
            onDismiss = viewModel::closeAddAccountSheet,
            onSave = viewModel::addManualAccount,
        )
    }

    // 微信扫码登录 BottomSheet
    if (uiState.showQrLoginSheet) {
        QrLoginSheet(
            editions = viewModel.editions,
            defaultEdition = viewModel.defaultEdition,
            loginService = app.loginService,
            onAuthorized = viewModel::onQrLoginAuthorized,
            onDismiss = viewModel::closeQrLoginSheet,
        )
    }
}
