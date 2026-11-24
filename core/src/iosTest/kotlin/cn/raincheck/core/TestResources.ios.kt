package cn.raincheck.core

import platform.Foundation.NSString
import platform.Foundation.NSUTF8StringEncoding
import platform.Foundation.stringWithContentsOfFile

internal actual fun readProtocolFile(relativePath: String): String {
    val candidates = listOf(
        "../protocol/$relativePath",
        "protocol/$relativePath",
    )
    for (path in candidates) {
        @Suppress("CAST_NEVER_SUCCEEDS")
        val text = NSString.stringWithContentsOfFile(path, encoding = NSUTF8StringEncoding, error = null)
        if (text != null) return text
    }
    error("iOS test 找不到协议文件: $relativePath")
}
