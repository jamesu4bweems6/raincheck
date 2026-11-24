package cn.raincheck.android.ui.components

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import cn.raincheck.android.ui.theme.RainCheckTheme

/**
 * 全屏 Edge-to-Edge 极光渐变背景。
 * 通过多层柔和径向光晕模拟深浅色毛玻璃底纹，绘制开销极低且在所有机型零卡顿。
 */
@Composable
fun AuroraGlassBackground(
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    val glass = RainCheckTheme.glass
    Box(modifier = modifier.fillMaxSize()) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            drawRect(
                brush = Brush.verticalGradient(
                    colors = listOf(glass.bgTop, glass.bgMid, glass.bgBottom),
                ),
            )
            // 左上极光青光晕
            drawCircle(
                brush = Brush.radialGradient(
                    colors = listOf(glass.orbPrimary, Color.Transparent),
                    center = Offset(size.width * 0.14f, size.height * 0.10f),
                    radius = size.minDimension * 0.78f,
                ),
                center = Offset(size.width * 0.14f, size.height * 0.10f),
                radius = size.minDimension * 0.78f,
            )
            // 右中极光靛光晕
            drawCircle(
                brush = Brush.radialGradient(
                    colors = listOf(glass.orbSecondary, Color.Transparent),
                    center = Offset(size.width * 0.90f, size.height * 0.36f),
                    radius = size.minDimension * 0.72f,
                ),
                center = Offset(size.width * 0.90f, size.height * 0.36f),
                radius = size.minDimension * 0.72f,
            )
            // 底部偏左极光冰蓝光晕
            drawCircle(
                brush = Brush.radialGradient(
                    colors = listOf(glass.orbTertiary, Color.Transparent),
                    center = Offset(size.width * 0.28f, size.height * 0.86f),
                    radius = size.minDimension * 0.74f,
                ),
                center = Offset(size.width * 0.28f, size.height * 0.86f),
                radius = size.minDimension * 0.74f,
            )
        }
        content()
    }
}

/**
 * 毛玻璃层次卡片：半透明底面 + 顶部高光渐变描边 + 可选语义微染色。
 */
@Composable
fun GlassCard(
    modifier: Modifier = Modifier,
    accentColor: Color? = null,
    elevated: Boolean = false,
    cornerRadius: Dp = 22.dp,
    contentPadding: PaddingValues = PaddingValues(16.dp),
    onClick: (() -> Unit)? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    val glass = RainCheckTheme.glass
    val shape = RoundedCornerShape(cornerRadius)
    val baseFill = if (elevated) glass.glassSurfaceElevated else glass.glassSurface
    val borderBrush = Brush.verticalGradient(
        colors = listOf(
            accentColor?.copy(alpha = if (glass.isDark) 0.42f else 0.34f) ?: glass.glassBorderTop,
            glass.glassBorderBottom,
        ),
    )

    val cardModifier = modifier
        .clip(shape)
        .background(baseFill)
        .then(
            if (accentColor != null) {
                Modifier.background(
                    Brush.linearGradient(
                        colors = listOf(
                            accentColor.copy(alpha = if (glass.isDark) 0.14f else 0.08f),
                            Color.Transparent,
                        ),
                    ),
                )
            } else {
                Modifier
            },
        )
        .border(width = 1.dp, brush = borderBrush, shape = shape)
        .then(
            if (onClick != null) {
                Modifier.clickable(onClick = onClick)
            } else {
                Modifier
            },
        )

    Column(
        modifier = cardModifier.padding(contentPadding),
        content = content,
    )
}

/**
 * 状态/参数/筛选胶囊：统一圆角与高光细描边。
 */
@Composable
fun GlassPill(
    text: String,
    color: Color,
    modifier: Modifier = Modifier,
    selected: Boolean = false,
    icon: ImageVector? = null,
    showDot: Boolean = false,
    onClick: (() -> Unit)? = null,
) {
    val glass = RainCheckTheme.glass
    val haptic = LocalHapticFeedback.current
    val fillColor by animateColorAsState(
        targetValue = when {
            selected -> color.copy(alpha = if (glass.isDark) 0.32f else 0.20f)
            else -> color.copy(alpha = if (glass.isDark) 0.14f else 0.10f)
        },
        label = "pillFill",
    )
    val borderColor by animateColorAsState(
        targetValue = when {
            selected -> color.copy(alpha = if (glass.isDark) 0.78f else 0.62f)
            else -> color.copy(alpha = if (glass.isDark) 0.28f else 0.22f)
        },
        label = "pillBorder",
    )
    val shape = RoundedCornerShape(999.dp)

    Row(
        modifier = modifier
            .clip(shape)
            .background(fillColor)
            .border(1.dp, borderColor, shape)
            .then(
                if (onClick != null) {
                    Modifier.clickable {
                        haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                        onClick()
                    }
                } else {
                    Modifier
                },
            )
            .padding(horizontal = 10.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        if (showDot) {
            Box(
                modifier = Modifier
                    .size(7.dp)
                    .clip(CircleShape)
                    .background(color),
            )
        }
        if (icon != null) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = color,
                modifier = Modifier.size(14.dp),
            )
        }
        Text(
            text = text,
            style = MaterialTheme.typography.labelMedium,
            color = if (glass.isDark) color.copy(alpha = 0.96f) else color,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/**
 * 语义提示横幅（非白名单域名警告、登录码拦截、存储异常或降级配置提醒）。
 */
@Composable
fun GlassBanner(
    title: String,
    message: String,
    accentColor: Color,
    icon: ImageVector,
    modifier: Modifier = Modifier,
    actionLabel: String? = null,
    onAction: (() -> Unit)? = null,
) {
    val glass = RainCheckTheme.glass
    val shape = RoundedCornerShape(18.dp)
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clip(shape)
            .background(accentColor.copy(alpha = if (glass.isDark) 0.18f else 0.11f))
            .border(1.dp, accentColor.copy(alpha = if (glass.isDark) 0.45f else 0.35f), shape)
            .padding(horizontal = 14.dp, vertical = 12.dp),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = accentColor,
            modifier = Modifier
                .padding(top = 1.dp)
                .size(20.dp),
        )
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(
                text = title,
                style = MaterialTheme.typography.titleSmall,
                color = accentColor,
            )
            Text(
                text = message,
                style = MaterialTheme.typography.bodySmall,
                color = glass.inkPrimary.copy(alpha = 0.88f),
            )
            if (actionLabel != null && onAction != null) {
                Spacer(modifier = Modifier.height(4.dp))
                GlassPill(
                    text = actionLabel,
                    color = accentColor,
                    selected = true,
                    onClick = onAction,
                )
            }
        }
    }
}

/**
 * 极光渐变主按钮（带触感反馈与加载态）。
 */
@Composable
fun AuroraPrimaryButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    icon: ImageVector? = null,
    enabled: Boolean = true,
    loading: Boolean = false,
) {
    val glass = RainCheckTheme.glass
    val haptic = LocalHapticFeedback.current
    val shape: Shape = RoundedCornerShape(18.dp)
    val effectiveEnabled = enabled && !loading
    val brush = if (effectiveEnabled) {
        Brush.horizontalGradient(
            colors = listOf(glass.accentTeal, glass.accentCyan, glass.accentIndigo),
        )
    } else {
        Brush.horizontalGradient(
            colors = listOf(
                glass.inkMuted.copy(alpha = 0.30f),
                glass.inkMuted.copy(alpha = 0.24f),
            ),
        )
    }
    val contentColor = if (effectiveEnabled) Color.White else glass.inkMuted

    Box(
        modifier = modifier
            .height(52.dp)
            .clip(shape)
            .background(brush)
            .border(
                width = 1.dp,
                color = Color.White.copy(alpha = if (effectiveEnabled) 0.34f else 0.10f),
                shape = shape,
            )
            .clickable(enabled = effectiveEnabled) {
                haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                onClick()
            }
            .padding(horizontal = 20.dp),
        contentAlignment = Alignment.Center,
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.Center,
        ) {
            if (loading) {
                CircularProgressIndicator(
                    modifier = Modifier.size(18.dp),
                    strokeWidth = 2.2.dp,
                    color = Color.White,
                )
                Spacer(modifier = Modifier.width(10.dp))
            } else if (icon != null) {
                Icon(
                    imageVector = icon,
                    contentDescription = null,
                    tint = contentColor,
                    modifier = Modifier.size(19.dp),
                )
                Spacer(modifier = Modifier.width(8.dp))
            }
            Text(
                text = text,
                style = MaterialTheme.typography.labelLarge,
                color = contentColor,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

/**
 * 毛玻璃次级操作按钮。
 */
@Composable
fun GlassTonalButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    icon: ImageVector? = null,
    accentColor: Color = RainCheckTheme.glass.accentTeal,
    enabled: Boolean = true,
) {
    val glass = RainCheckTheme.glass
    val haptic = LocalHapticFeedback.current
    val shape = RoundedCornerShape(16.dp)
    val tint = if (enabled) accentColor else glass.inkMuted

    Surface(
        modifier = modifier.height(44.dp),
        shape = shape,
        color = if (enabled) {
            accentColor.copy(alpha = if (glass.isDark) 0.16f else 0.11f)
        } else {
            glass.glassSurfaceSubtle
        },
        border = BorderStroke(
            width = 1.dp,
            color = if (enabled) {
                accentColor.copy(alpha = if (glass.isDark) 0.38f else 0.28f)
            } else {
                glass.glassBorderBottom
            },
        ),
        onClick = {
            if (enabled) {
                haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                onClick()
            }
        },
        enabled = enabled,
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.Center,
        ) {
            if (icon != null) {
                Icon(
                    imageVector = icon,
                    contentDescription = null,
                    tint = tint,
                    modifier = Modifier.size(18.dp),
                )
                Spacer(modifier = Modifier.width(6.dp))
            }
            Text(
                text = text,
                style = MaterialTheme.typography.labelLarge,
                color = tint,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@Composable
fun SectionHeader(
    title: String,
    subtitle: String? = null,
    modifier: Modifier = Modifier,
    trailing: @Composable (() -> Unit)? = null,
) {
    val glass = RainCheckTheme.glass
    Row(
        modifier = modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = title,
                style = MaterialTheme.typography.titleMedium,
                color = glass.inkPrimary,
            )
            if (!subtitle.isNullOrBlank()) {
                Text(
                    text = subtitle,
                    style = MaterialTheme.typography.bodySmall,
                    color = glass.inkSecondary,
                )
            }
        }
        if (trailing != null) {
            Spacer(modifier = Modifier.width(8.dp))
            trailing()
        }
    }
}

data class NavDestination(
    val key: String,
    val label: String,
    val icon: ImageVector,
    val badgeCount: Int = 0,
    val pulsing: Boolean = false,
)

/**
 * 悬浮胶囊毛玻璃底部导航栏（单 Activity + Compose 状态驱动）。
 */
@Composable
fun FloatingGlassNavBar(
    destinations: List<NavDestination>,
    selectedKey: String,
    onSelect: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val glass = RainCheckTheme.glass
    val haptic = LocalHapticFeedback.current
    val outerShape = RoundedCornerShape(30.dp)

    Box(
        modifier = modifier
            .fillMaxWidth()
            .navigationBarsPadding()
            .padding(horizontal = 18.dp, vertical = 10.dp),
        contentAlignment = Alignment.Center,
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .shadow(
                    elevation = if (glass.isDark) 18.dp else 14.dp,
                    shape = outerShape,
                    ambientColor = glass.accentTeal.copy(alpha = 0.20f),
                    spotColor = glass.accentIndigo.copy(alpha = 0.22f),
                )
                .clip(outerShape)
                .background(glass.navBarSurface)
                .border(
                    width = 1.dp,
                    brush = Brush.verticalGradient(
                        colors = listOf(glass.navBarBorder, glass.glassBorderBottom),
                    ),
                    shape = outerShape,
                )
                .padding(horizontal = 6.dp, vertical = 6.dp),
            horizontalArrangement = Arrangement.SpaceEvenly,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            destinations.forEach { dest ->
                val selected = dest.key == selectedKey
                val pillBg by animateColorAsState(
                    targetValue = if (selected) glass.navActivePill else Color.Transparent,
                    label = "navPillBg",
                )
                val tint by animateColorAsState(
                    targetValue = if (selected) glass.accentTeal else glass.inkSecondary,
                    label = "navTint",
                )
                val horizPad by animateDpAsState(
                    targetValue = if (selected) 16.dp else 10.dp,
                    animationSpec = spring(stiffness = Spring.StiffnessMediumLow),
                    label = "navPad",
                )

                Row(
                    modifier = Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(24.dp))
                        .background(pillBg)
                        .clickable(
                            interactionSource = remember { MutableInteractionSource() },
                            indication = null,
                        ) {
                            if (!selected) {
                                haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                                onSelect(dest.key)
                            }
                        }
                        .padding(horizontal = horizPad, vertical = 10.dp),
                    horizontalArrangement = Arrangement.Center,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box {
                        Icon(
                            imageVector = dest.icon,
                            contentDescription = dest.label,
                            tint = tint,
                            modifier = Modifier.size(20.dp),
                        )
                        if (dest.badgeCount > 0 || dest.pulsing) {
                            Box(
                                modifier = Modifier
                                    .align(Alignment.TopEnd)
                                    .size(7.dp)
                                    .clip(CircleShape)
                                    .background(if (dest.pulsing) glass.accentCyan else glass.statusSuccess),
                            )
                        }
                    }
                    Spacer(modifier = Modifier.width(6.dp))
                    Text(
                        text = dest.label,
                        style = MaterialTheme.typography.labelMedium.copy(
                            fontWeight = if (selected) FontWeight.Bold else FontWeight.Medium,
                        ),
                        color = tint,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
    }
}
