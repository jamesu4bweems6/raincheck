package cn.raincheck.android.util

import android.graphics.Bitmap
import android.graphics.Color
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * 登录二维码渲染（纯 ZXing Core）。
 *
 * 颜色固定为高对比度深墨/纯白，避免深色主题反色导致微信无法识别；
 * 提供 [bitmapAsync] 在 [Dispatchers.Default] 后台线程生成位图，绝不阻塞主线程。
 */
object QrRender {

    suspend fun bitmapAsync(content: String, sizePx: Int = 720): Bitmap =
        withContext(Dispatchers.Default) {
            bitmap(content, sizePx)
        }

    fun bitmap(content: String, sizePx: Int = 640): Bitmap {
        val hints = mapOf<EncodeHintType, Any>(
            EncodeHintType.MARGIN to 1,
            EncodeHintType.CHARACTER_SET to "UTF-8",
        )
        val matrix = QRCodeWriter().encode(content, BarcodeFormat.QR_CODE, sizePx, sizePx, hints)
        val width = matrix.width
        val height = matrix.height
        val pixels = IntArray(width * height)
        for (y in 0 until height) {
            val rowOffset = y * width
            for (x in 0 until width) {
                pixels[rowOffset + x] = if (matrix.get(x, y)) Color.BLACK else Color.WHITE
            }
        }
        return Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).apply {
            setPixels(pixels, 0, width, 0, 0, width, height)
        }
    }
}
