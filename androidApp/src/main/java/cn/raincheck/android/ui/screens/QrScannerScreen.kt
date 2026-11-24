package cn.raincheck.android.ui.screens

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import android.util.Log
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import android.util.Size as AndroidSize
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CameraAlt
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.FlashOff
import androidx.compose.material.icons.rounded.FlashOn
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import cn.raincheck.android.ui.components.AuroraPrimaryButton
import cn.raincheck.android.ui.components.GlassCard
import cn.raincheck.android.ui.components.GlassTonalButton
import cn.raincheck.android.ui.theme.RainCheckTheme
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.MultiFormatReader
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.common.GlobalHistogramBinarizer
import com.google.zxing.common.HybridBinarizer
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 全新 AndroidX CameraX (Camera2) + 纯 ZXing Core 二维码扫描界面。
 *
 * 特点：
 * - 零 GMS 依赖、国产机型通用；
 * - 原生竖屏取景，自动选择后置相机（不再硬编码 cameraId=0），支持手电筒；
 * - 单次防抖回调（[AtomicBoolean]），扫到即停且绝不自动提交签到。
 */
@Composable
fun QrScannerScreen(
    onScanned: (String) -> Unit,
    onClose: () -> Unit,
) {
    val context = LocalContext.current
    val haptic = LocalHapticFeedback.current
    val glass = RainCheckTheme.glass

    BackHandler(onBack = onClose)

    var hasCameraPermission by remember {
        mutableStateOf(
            ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) ==
                PackageManager.PERMISSION_GRANTED,
        )
    }
    var permissionRequested by remember { mutableStateOf(false) }

    val permissionLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestPermission(),
    ) { granted ->
        hasCameraPermission = granted
        permissionRequested = true
    }

    LaunchedEffect(Unit) {
        if (!hasCameraPermission && !permissionRequested) {
            permissionLauncher.launch(Manifest.permission.CAMERA)
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color(0xFF040B12)),
    ) {
        if (hasCameraPermission) {
            var torchEnabled by remember { mutableStateOf(false) }
            var hasFlash by remember { mutableStateOf(false) }
            var cameraError by remember { mutableStateOf<String?>(null) }
            var boundCamera by remember { mutableStateOf<Camera?>(null) }

            CameraXQrPreview(
                onQrDetected = { raw ->
                    haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                    onScanned(raw)
                },
                onCameraBound = { camera ->
                    boundCamera = camera
                    hasFlash = camera.cameraInfo.hasFlashUnit()
                },
                onError = { msg -> cameraError = msg },
            )

            ScannerReticleOverlay()

            // 顶部悬浮毛玻璃控制栏
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .statusBarsPadding()
                    .padding(horizontal = 16.dp, vertical = 14.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                ScannerCircleAction(
                    icon = Icons.Rounded.Close,
                    contentDescription = "关闭扫码",
                    onClick = onClose,
                )
                Text(
                    text = "扫描课堂签到码",
                    style = MaterialTheme.typography.titleMedium,
                    color = Color.White,
                    modifier = Modifier
                        .clip(RoundedCornerShape(999.dp))
                        .background(Color(0x88081826))
                        .border(1.dp, Color.White.copy(alpha = 0.22f), RoundedCornerShape(999.dp))
                        .padding(horizontal = 16.dp, vertical = 8.dp),
                )
                if (hasFlash) {
                    ScannerCircleAction(
                        icon = if (torchEnabled) Icons.Rounded.FlashOn else Icons.Rounded.FlashOff,
                        contentDescription = if (torchEnabled) "关闭手电筒" else "打开手电筒",
                        active = torchEnabled,
                        onClick = {
                            val next = !torchEnabled
                            torchEnabled = next
                            boundCamera?.cameraControl?.enableTorch(next)
                        },
                    )
                } else {
                    Spacer(modifier = Modifier.size(44.dp))
                }
            }

            // 底部引导提示卡
            Column(
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .fillMaxWidth()
                    .navigationBarsPadding()
                    .padding(horizontal = 24.dp, vertical = 28.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                if (cameraError != null) {
                    Text(
                        text = cameraError.orEmpty(),
                        style = MaterialTheme.typography.bodySmall,
                        color = glass.statusFailed,
                        textAlign = TextAlign.Center,
                        modifier = Modifier
                            .clip(RoundedCornerShape(14.dp))
                            .background(Color(0xCC1E1014))
                            .padding(horizontal = 14.dp, vertical = 8.dp),
                    )
                }
                Text(
                    text = "将雨课堂签到二维码放入取景框\n识别后仅自动解析，不会零点击提交",
                    style = MaterialTheme.typography.bodySmall,
                    color = Color.White.copy(alpha = 0.90f),
                    textAlign = TextAlign.Center,
                    modifier = Modifier
                        .clip(RoundedCornerShape(16.dp))
                        .background(Color(0x99071724))
                        .border(1.dp, Color.White.copy(alpha = 0.18f), RoundedCornerShape(16.dp))
                        .padding(horizontal = 18.dp, vertical = 12.dp),
                )
            }
        } else {
            // 优雅的权限引导界面
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .statusBarsPadding()
                    .navigationBarsPadding()
                    .padding(24.dp),
                verticalArrangement = Arrangement.Center,
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                GlassCard(
                    modifier = Modifier.fillMaxWidth(),
                    elevated = true,
                ) {
                    Column(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(14.dp),
                    ) {
                        Box(
                            modifier = Modifier
                                .size(60.dp)
                                .clip(CircleShape)
                                .background(glass.accentTeal.copy(alpha = 0.16f)),
                            contentAlignment = Alignment.Center,
                        ) {
                            Icon(
                                imageVector = Icons.Rounded.CameraAlt,
                                contentDescription = null,
                                tint = glass.accentTeal,
                                modifier = Modifier.size(30.dp),
                            )
                        }
                        Text(
                            text = "需要相机权限以扫描签到码",
                            style = MaterialTheme.typography.titleMedium,
                            color = glass.inkPrimary,
                            textAlign = TextAlign.Center,
                        )
                        Text(
                            text = "RainCheck 使用本机 CameraX 离线解析二维码，图像不会上传至任何服务器。你也可以返回直接粘贴链接或文本。",
                            style = MaterialTheme.typography.bodySmall,
                            color = glass.inkSecondary,
                            textAlign = TextAlign.Center,
                        )
                        AuroraPrimaryButton(
                            text = "授予相机权限",
                            icon = Icons.Rounded.CameraAlt,
                            onClick = { permissionLauncher.launch(Manifest.permission.CAMERA) },
                            modifier = Modifier.fillMaxWidth(),
                        )
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(10.dp),
                        ) {
                            GlassTonalButton(
                                text = "系统设置",
                                icon = Icons.Rounded.Settings,
                                onClick = {
                                    val intent = Intent(
                                        Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                        Uri.fromParts("package", context.packageName, null),
                                    )
                                    runCatching { context.startActivity(intent) }
                                },
                                modifier = Modifier.weight(1f),
                            )
                            GlassTonalButton(
                                text = "返回粘贴",
                                onClick = onClose,
                                accentColor = glass.inkSecondary,
                                modifier = Modifier.weight(1f),
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ScannerCircleAction(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    contentDescription: String,
    active: Boolean = false,
    onClick: () -> Unit,
) {
    val bg = if (active) Color(0xCC0D9488) else Color(0x88081826)
    IconButton(
        onClick = onClick,
        modifier = Modifier
            .size(44.dp)
            .clip(CircleShape)
            .background(bg)
            .border(1.dp, Color.White.copy(alpha = 0.25f), CircleShape),
    ) {
        Icon(
            imageVector = icon,
            contentDescription = contentDescription,
            tint = Color.White,
        )
    }
}

@Composable
private fun CameraXQrPreview(
    onQrDetected: (String) -> Unit,
    onCameraBound: (Camera) -> Unit,
    onError: (String) -> Unit,
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val mainExecutor = remember(context) { ContextCompat.getMainExecutor(context) }
    val delivered = remember { AtomicBoolean(false) }

    val previewView = remember {
        PreviewView(context).apply {
            implementationMode = PreviewView.ImplementationMode.COMPATIBLE
            scaleType = PreviewView.ScaleType.FILL_CENTER
        }
    }

    DisposableEffect(lifecycleOwner) {
        val disposed = AtomicBoolean(false)
        val analysisExecutor = Executors.newSingleThreadExecutor()
        val providerFuture = ProcessCameraProvider.getInstance(context)
        var cameraProvider: ProcessCameraProvider? = null

        providerFuture.addListener(
            {
                if (disposed.get()) return@addListener
                runCatching {
                    val provider = providerFuture.get()
                    if (disposed.get()) return@addListener
                    cameraProvider = provider

                    val selector = when {
                        provider.hasCamera(CameraSelector.DEFAULT_BACK_CAMERA) ->
                            CameraSelector.DEFAULT_BACK_CAMERA
                        provider.hasCamera(CameraSelector.DEFAULT_FRONT_CAMERA) ->
                            CameraSelector.DEFAULT_FRONT_CAMERA
                        else -> throw IllegalStateException("设备未检测到可用摄像头")
                    }

                    val preview = Preview.Builder().build().also {
                        it.surfaceProvider = previewView.surfaceProvider
                    }

                    val resolutionSelector = ResolutionSelector.Builder()
                        .setResolutionStrategy(
                            ResolutionStrategy(
                                AndroidSize(1280, 720),
                                ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER,
                            ),
                        )
                        .build()

                    val analysis = ImageAnalysis.Builder()
                        .setResolutionSelector(resolutionSelector)
                        .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                        .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_YUV_420_888)
                        .build()

                    analysis.setAnalyzer(
                        analysisExecutor,
                        ZxingQrImageAnalyzer(
                            delivered = delivered,
                            onResult = { content ->
                                mainExecutor.execute {
                                    if (!disposed.get()) onQrDetected(content)
                                }
                            },
                        ),
                    )

                    provider.unbindAll()
                    if (disposed.get()) return@addListener
                    val camera = provider.bindToLifecycle(lifecycleOwner, selector, preview, analysis)
                    onCameraBound(camera)
                }.onFailure { err ->
                    if (!disposed.get()) {
                        Log.e("QrScannerScreen", "CameraX 初始化失败", err)
                        onError("相机启动失败：${err.message ?: err.javaClass.simpleName}")
                    }
                }
            },
            mainExecutor,
        )

        onDispose {
            disposed.set(true)
            runCatching { cameraProvider?.unbindAll() }
            analysisExecutor.shutdown()
        }
    }

    AndroidView(
        factory = { previewView },
        modifier = Modifier.fillMaxSize(),
    )
}

@Composable
private fun ScannerReticleOverlay() {
    val infinite = rememberInfiniteTransition(label = "scanLine")
    val lineProgress by infinite.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 2200, easing = LinearEasing),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "scanLineProgress",
    )

    Canvas(
        modifier = Modifier
            .fillMaxSize()
            .graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen },
    ) {
        val boxSide = (size.minDimension * 0.68f).coerceAtMost(320.dp.toPx())
        val left = (size.width - boxSide) / 2f
        val top = (size.height - boxSide) / 2f - 24.dp.toPx()
        val rect = Rect(Offset(left, top), Size(boxSide, boxSide))
        val cornerRadius = 24.dp.toPx()

        // 半透明深色遮罩 + 镂空取景窗
        drawRect(color = Color(0x9E040C14))
        drawRoundRect(
            color = Color.Transparent,
            topLeft = rect.topLeft,
            size = rect.size,
            cornerRadius = CornerRadius(cornerRadius, cornerRadius),
            blendMode = BlendMode.Clear,
        )

        // 细微边框
        drawRoundRect(
            color = Color.White.copy(alpha = 0.28f),
            topLeft = rect.topLeft,
            size = rect.size,
            cornerRadius = CornerRadius(cornerRadius, cornerRadius),
            style = Stroke(width = 1.2.dp.toPx()),
        )

        // 四角极光青发光拐角
        val accent = Color(0xFF2DD4BF)
        val stroke = 4.dp.toPx()
        val arm = 30.dp.toPx()
        val r = rect
        // 左上
        drawLine(accent, Offset(r.left, r.top + arm), Offset(r.left, r.top + 8f), stroke, StrokeCap.Round)
        drawLine(accent, Offset(r.left + 8f, r.top), Offset(r.left + arm, r.top), stroke, StrokeCap.Round)
        // 右上
        drawLine(accent, Offset(r.right - arm, r.top), Offset(r.right - 8f, r.top), stroke, StrokeCap.Round)
        drawLine(accent, Offset(r.right, r.top + 8f), Offset(r.right, r.top + arm), stroke, StrokeCap.Round)
        // 左下
        drawLine(accent, Offset(r.left, r.bottom - arm), Offset(r.left, r.bottom - 8f), stroke, StrokeCap.Round)
        drawLine(accent, Offset(r.left + 8f, r.bottom), Offset(r.left + arm, r.bottom), stroke, StrokeCap.Round)
        // 右下
        drawLine(accent, Offset(r.right - arm, r.bottom), Offset(r.right - 8f, r.bottom), stroke, StrokeCap.Round)
        drawLine(accent, Offset(r.right, r.bottom - arm), Offset(r.right, r.bottom - 8f), stroke, StrokeCap.Round)

        // 柔和扫描光束
        val laserY = r.top + 18.dp.toPx() + (r.height - 36.dp.toPx()) * lineProgress
        drawLine(
            brush = Brush.horizontalGradient(
                colors = listOf(Color.Transparent, accent, Color(0xFF38BDF8), Color.Transparent),
                startX = r.left + 12.dp.toPx(),
                endX = r.right - 12.dp.toPx(),
            ),
            start = Offset(r.left + 14.dp.toPx(), laserY),
            end = Offset(r.right - 14.dp.toPx(), laserY),
            strokeWidth = 2.6.dp.toPx(),
            cap = StrokeCap.Round,
        )
    }
}

/**
 * 纯 ZXing Core YUV 帧解析器：
 * - 严格按 `rowStride` / `pixelStride` 提取亮度平面，兼容各品牌机型相机对齐填充；
 * - 依次尝试 `HybridBinarizer` 与 `GlobalHistogramBinarizer` 并支持反色屏幕码；
 * - 节流每 120ms 解码一帧 + [AtomicBoolean] 保证单次防抖防重回调。
 */
private class ZxingQrImageAnalyzer(
    private val delivered: AtomicBoolean,
    private val onResult: (String) -> Unit,
) : ImageAnalysis.Analyzer {

    private val reader = MultiFormatReader().apply {
        setHints(
            mapOf(
                DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE),
                DecodeHintType.TRY_HARDER to true,
                DecodeHintType.ALSO_INVERTED to true,
                DecodeHintType.CHARACTER_SET to "UTF-8",
            ),
        )
    }

    private var lastAnalyzedAtMs = 0L
    private var yBuffer = ByteArray(0)

    override fun analyze(image: ImageProxy) {
        try {
            if (delivered.get()) return
            val now = System.currentTimeMillis()
            if (now - lastAnalyzedAtMs < 120L) return
            lastAnalyzedAtMs = now

            val plane = image.planes.firstOrNull() ?: return
            val width = image.width
            val height = image.height
            if (width <= 0 || height <= 0) return

            val luminance = extractYPlane(plane, width, height)
            val source = PlanarYUVLuminanceSource(
                luminance,
                width,
                height,
                0,
                0,
                width,
                height,
                false,
            )

            val decoded = decodeSafe(BinaryBitmap(HybridBinarizer(source)))
                ?: decodeSafe(BinaryBitmap(GlobalHistogramBinarizer(source)))

            val text = decoded?.trim()
            if (!text.isNullOrEmpty() && delivered.compareAndSet(false, true)) {
                onResult(text)
            }
        } finally {
            image.close()
        }
    }

    private fun extractYPlane(plane: ImageProxy.PlaneProxy, width: Int, height: Int): ByteArray {
        val required = width * height
        if (yBuffer.size != required) {
            yBuffer = ByteArray(required)
        }
        val buffer = plane.buffer
        buffer.rewind()
        val rowStride = plane.rowStride
        val pixelStride = plane.pixelStride

        if (pixelStride == 1 && rowStride == width) {
            buffer.get(yBuffer, 0, required)
            return yBuffer
        }

        val rowData = ByteArray(rowStride)
        for (row in 0 until height) {
            val bytesToRead = minOf(rowStride, buffer.remaining())
            if (bytesToRead <= 0) break
            buffer.get(rowData, 0, bytesToRead)
            val dstOffset = row * width
            if (pixelStride == 1) {
                System.arraycopy(rowData, 0, yBuffer, dstOffset, minOf(width, bytesToRead))
            } else {
                for (col in 0 until width) {
                    val srcIdx = col * pixelStride
                    if (srcIdx < bytesToRead) {
                        yBuffer[dstOffset + col] = rowData[srcIdx]
                    }
                }
            }
        }
        return yBuffer
    }

    private fun decodeSafe(bitmap: BinaryBitmap): String? {
        return try {
            reader.decodeWithState(bitmap).text
        } catch (_: Throwable) {
            null
        } finally {
            reader.reset()
        }
    }
}
