package cn.raincheck.android.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

/**
 * 极光毛玻璃（Aurora Frosted Glass）语义色板。
 * 自适应深浅色系统主题，与 iOS 27 液态玻璃视觉体系遥相呼应，同时贴合 Material 3 Edge-to-Edge。
 */
@Immutable
data class GlassPalette(
    val isDark: Boolean,
    val bgTop: Color,
    val bgMid: Color,
    val bgBottom: Color,
    val orbPrimary: Color,
    val orbSecondary: Color,
    val orbTertiary: Color,
    val glassSurface: Color,
    val glassSurfaceElevated: Color,
    val glassSurfaceSubtle: Color,
    val glassBorderTop: Color,
    val glassBorderBottom: Color,
    val navBarSurface: Color,
    val navBarBorder: Color,
    val navActivePill: Color,
    val inkPrimary: Color,
    val inkSecondary: Color,
    val inkMuted: Color,
    val accentTeal: Color,
    val accentCyan: Color,
    val accentIndigo: Color,
    val statusSuccess: Color,
    val statusAlready: Color,
    val statusDryRun: Color,
    val statusAuth: Color,
    val statusExpired: Color,
    val statusFailed: Color,
    val statusNeutral: Color,
    val codeSurface: Color,
)

private val LightGlassPalette = GlassPalette(
    isDark = false,
    bgTop = Color(0xFFE9F4F7),
    bgMid = Color(0xFFEBF0FB),
    bgBottom = Color(0xFFF3EEFA),
    orbPrimary = Color(0x4D14B8A6),
    orbSecondary = Color(0x3D4F46E5),
    orbTertiary = Color(0x3306B6D4),
    glassSurface = Color(0xC2FFFFFF),
    glassSurfaceElevated = Color(0xDCFFFFFF),
    glassSurfaceSubtle = Color(0x88FFFFFF),
    glassBorderTop = Color(0xE6FFFFFF),
    glassBorderBottom = Color(0x2E0E7490),
    navBarSurface = Color(0xDBFFFFFF),
    navBarBorder = Color(0xB8FFFFFF),
    navActivePill = Color(0x260D9488),
    inkPrimary = Color(0xFF0A1D26),
    inkSecondary = Color(0xFF3F5B68),
    inkMuted = Color(0xFF6B8490),
    accentTeal = Color(0xFF0B8A8E),
    accentCyan = Color(0xFF0284C7),
    accentIndigo = Color(0xFF4F46E5),
    statusSuccess = Color(0xFF059669),
    statusAlready = Color(0xFF0891B2),
    statusDryRun = Color(0xFF4F46E5),
    statusAuth = Color(0xFFD97706),
    statusExpired = Color(0xFF9333EA),
    statusFailed = Color(0xFFDC2626),
    statusNeutral = Color(0xFF475569),
    codeSurface = Color(0x140A1D26),
)

private val DarkGlassPalette = GlassPalette(
    isDark = true,
    bgTop = Color(0xFF050E17),
    bgMid = Color(0xFF091726),
    bgBottom = Color(0xFF0C1224),
    orbPrimary = Color(0x4514B8A6),
    orbSecondary = Color(0x423B82F6),
    orbTertiary = Color(0x3A8B5CF6),
    glassSurface = Color(0xAD0F2232),
    glassSurfaceElevated = Color(0xCC132B3E),
    glassSurfaceSubtle = Color(0x780D1C2B),
    glassBorderTop = Color(0x38E2F8FF),
    glassBorderBottom = Color(0x1A2DD4BF),
    navBarSurface = Color(0xD80C1C2B),
    navBarBorder = Color(0x36BAE6FD),
    navActivePill = Color(0x382DD4BF),
    inkPrimary = Color(0xFFF0F9FF),
    inkSecondary = Color(0xFFA6C0CE),
    inkMuted = Color(0xFF6F8A9A),
    accentTeal = Color(0xFF2DD4BF),
    accentCyan = Color(0xFF38BDF8),
    accentIndigo = Color(0xFF818CF8),
    statusSuccess = Color(0xFF34D399),
    statusAlready = Color(0xFF22D3EE),
    statusDryRun = Color(0xFF818CF8),
    statusAuth = Color(0xFFFBBF24),
    statusExpired = Color(0xFFC084FC),
    statusFailed = Color(0xFFF87171),
    statusNeutral = Color(0xFF94A3B8),
    codeSurface = Color(0x4D020617),
)

private val LightColorScheme = lightColorScheme(
    primary = Color(0xFF0B8A8E),
    onPrimary = Color.White,
    primaryContainer = Color(0xFFC7F2F0),
    onPrimaryContainer = Color(0xFF042F33),
    secondary = Color(0xFF4F46E5),
    onSecondary = Color.White,
    secondaryContainer = Color(0xFFE0E7FF),
    onSecondaryContainer = Color(0xFF1E1B4B),
    tertiary = Color(0xFF0284C7),
    onTertiary = Color.White,
    background = Color(0xFFE9F4F7),
    onBackground = Color(0xFF0A1D26),
    surface = Color(0xFFF4FAFC),
    onSurface = Color(0xFF0A1D26),
    surfaceVariant = Color(0xFFDCECF0),
    onSurfaceVariant = Color(0xFF3F5B68),
    outline = Color(0xFF8FB0BC),
    error = Color(0xFFDC2626),
    onError = Color.White,
)

private val DarkColorScheme = darkColorScheme(
    primary = Color(0xFF2DD4BF),
    onPrimary = Color(0xFF042426),
    primaryContainer = Color(0xFF0D4A4C),
    onPrimaryContainer = Color(0xFFCCFBF1),
    secondary = Color(0xFF818CF8),
    onSecondary = Color(0xFF13113B),
    secondaryContainer = Color(0xFF2B286E),
    onSecondaryContainer = Color(0xFFE0E7FF),
    tertiary = Color(0xFF38BDF8),
    onTertiary = Color(0xFF052436),
    background = Color(0xFF050E17),
    onBackground = Color(0xFFF0F9FF),
    surface = Color(0xFF0B1926),
    onSurface = Color(0xFFF0F9FF),
    surfaceVariant = Color(0xFF142838),
    onSurfaceVariant = Color(0xFFA6C0CE),
    outline = Color(0xFF355163),
    error = Color(0xFFF87171),
    onError = Color(0xFF3B0909),
)

private val RainCheckTypography = Typography(
    headlineLarge = TextStyle(
        fontWeight = FontWeight.Bold,
        fontSize = 28.sp,
        lineHeight = 34.sp,
        letterSpacing = (-0.4).sp,
    ),
    headlineSmall = TextStyle(
        fontWeight = FontWeight.Bold,
        fontSize = 21.sp,
        lineHeight = 27.sp,
        letterSpacing = (-0.2).sp,
    ),
    titleMedium = TextStyle(
        fontWeight = FontWeight.SemiBold,
        fontSize = 16.sp,
        lineHeight = 22.sp,
    ),
    titleSmall = TextStyle(
        fontWeight = FontWeight.SemiBold,
        fontSize = 14.sp,
        lineHeight = 19.sp,
    ),
    bodyMedium = TextStyle(
        fontWeight = FontWeight.Normal,
        fontSize = 14.sp,
        lineHeight = 20.sp,
    ),
    bodySmall = TextStyle(
        fontWeight = FontWeight.Normal,
        fontSize = 12.sp,
        lineHeight = 17.sp,
    ),
    labelLarge = TextStyle(
        fontWeight = FontWeight.SemiBold,
        fontSize = 14.sp,
        lineHeight = 18.sp,
    ),
    labelMedium = TextStyle(
        fontWeight = FontWeight.Medium,
        fontSize = 12.sp,
        lineHeight = 16.sp,
    ),
    labelSmall = TextStyle(
        fontFamily = FontFamily.Monospace,
        fontWeight = FontWeight.Medium,
        fontSize = 11.sp,
        lineHeight = 15.sp,
    ),
)

val LocalGlassPalette = staticCompositionLocalOf { LightGlassPalette }

object RainCheckTheme {
    val glass: GlassPalette
        @Composable get() = LocalGlassPalette.current
}

@Composable
fun RainCheckTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    val palette = if (darkTheme) DarkGlassPalette else LightGlassPalette
    val scheme = if (darkTheme) DarkColorScheme else LightColorScheme

    CompositionLocalProvider(LocalGlassPalette provides palette) {
        MaterialTheme(
            colorScheme = scheme,
            typography = RainCheckTypography,
            content = content,
        )
    }
}

/** 按雨课堂站点 / 校区给出辨识度高且协调的主题色。 */
fun campusAccentColor(host: String, isDark: Boolean): Color {
    val lower = host.lowercase()
    return when {
        lower.contains("pro.yuketang") -> if (isDark) Color(0xFFA78BFA) else Color(0xFF6D28D9)
        lower.contains("changjiang") -> if (isDark) Color(0xFF38BDF8) else Color(0xFF0284C7)
        lower.contains("huanghe") -> if (isDark) Color(0xFFFBBF24) else Color(0xFFD97706)
        lower.contains("xuetangx") -> if (isDark) Color(0xFF34D399) else Color(0xFF059669)
        lower.contains("127.0.0.1") || lower.contains("localhost") ->
            if (isDark) Color(0xFF94A3B8) else Color(0xFF475569)
        lower.contains("www.yuketang") -> if (isDark) Color(0xFF2DD4BF) else Color(0xFF0B8A8E)
        else -> if (isDark) Color(0xFFF472B6) else Color(0xFFBE185D)
    }
}
