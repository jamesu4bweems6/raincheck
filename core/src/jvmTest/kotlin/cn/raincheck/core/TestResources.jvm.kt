package cn.raincheck.core

import java.io.File
import java.nio.charset.StandardCharsets

internal actual fun readProtocolFile(relativePath: String): String {
    val cl = Thread.currentThread().contextClassLoader
    val stream = cl.getResourceAsStream(relativePath)
        ?: cl.getResourceAsStream("/$relativePath")
    if (stream != null) {
        return stream.bufferedReader(StandardCharsets.UTF_8).use { it.readText() }
    }
    val candidates = listOf(
        File("../protocol/$relativePath"),
        File("protocol/$relativePath"),
    )
    val file = candidates.firstOrNull { it.exists() }
        ?: error("测试找不到协议文件: $relativePath (cwd=${File(".").absolutePath})")
    return file.readText(StandardCharsets.UTF_8)
}
