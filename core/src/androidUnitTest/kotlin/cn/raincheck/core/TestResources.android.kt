package cn.raincheck.core

import java.io.File
import java.nio.charset.StandardCharsets

internal actual fun readProtocolFile(relativePath: String): String {
    val candidates = listOf(
        File("../protocol/$relativePath"),
        File("protocol/$relativePath"),
    )
    val file = candidates.firstOrNull { it.exists() }
        ?: error("Android unit test 找不到协议文件: $relativePath")
    return file.readText(StandardCharsets.UTF_8)
}
