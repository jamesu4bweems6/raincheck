package cn.raincheck.android.data

import android.content.Context
import android.content.Intent
import androidx.core.content.FileProvider
import cn.raincheck.core.SignBatchReport
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import java.io.File
import java.security.SecureRandom
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 脱敏安全报告导出器。
 *
 * 安全约束：
 * - 严格写入内部 `cacheDir/reports/`，绝不落盘到外部公共存储；
 * - 文件名精确到毫秒并附随机后缀，杜绝连点覆写冲突；
 * - 绝不序列化账号凭据（Bearer / sessionid / csrftoken），并对文本内潜在凭据模式执行正则脱敏与长度截断；
 * - 通过 `FileProvider` 临时授权 URI 调用系统分享，用完自动清理旧缓存文件。
 */
object ReportExporter {

    private val json = Json { prettyPrint = true }
    private val random = SecureRandom()

    private const val REPORTS_SUBDIR = "reports"
    private const val MAX_BODY_CHARS = 1500
    private const val MAX_CACHED_REPORTS = 20

    private val bearerRegex = Regex("""(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{6,}""")
    private val cookieSecretRegex = Regex("""(?i)\b(sessionid|csrftoken|set-auth|authorization)\s*[:=]\s*[^\s;,"'}]+""")

    fun export(context: Context, report: SignBatchReport): File {
        val root = buildJsonObject {
            put("app", "RainCheck Android")
            put("sanitized", true)
            put("exportedAt", System.currentTimeMillis())
            put("startedAt", report.startedAt)
            put("finishedAt", report.finishedAt)
            put("elapsedMs", report.elapsedMs)
            put("successCount", report.successCount)
            put("dryRunCount", report.dryRunCount)
            put("failedCount", report.failedCount)

            putJsonObject("ticket") {
                put("raw", sanitizeText(report.ticket.raw, 600))
                put("kind", report.ticket.kind.name)
                put("summary", sanitizeText(report.ticket.summary(), 240))
                put("url", report.ticket.url?.let { sanitizeText(it, 600) })
                put("host", report.ticket.host)
                put("lessonId", report.ticket.lessonId)
                put("classroomId", report.ticket.classroomId)
                put("checkinId", report.ticket.checkinId)
                putJsonObject("params") {
                    report.ticket.params.forEach { (key, value) ->
                        put(key, sanitizeText(value, 240))
                    }
                }
            }

            putJsonArray("results") {
                report.results.forEach { result ->
                    addJsonObject {
                        put("accountId", result.accountId)
                        put("label", result.label)
                        put("state", result.state.name)
                        put("ok", result.ok)
                        put("message", sanitizeText(result.message, 400))
                        put("strategy", result.strategy)
                        put("lessonId", result.lessonId)
                        putJsonArray("attempts") {
                            result.attempts.forEach { attempt ->
                                addJsonObject {
                                    put("strategy", attempt.strategy)
                                    put("httpStatus", attempt.httpStatus)
                                    put("code", attempt.code)
                                    put("message", attempt.message?.let { sanitizeText(it, 400) })
                                    put("ok", attempt.ok)
                                    put("requestLine", sanitizeText(attempt.requestLine, 500))
                                    put("requestBody", attempt.requestBody?.let { sanitizeText(it, MAX_BODY_CHARS) })
                                    put("responseBody", attempt.responseBody?.let { sanitizeText(it, MAX_BODY_CHARS) })
                                    put("elapsedMs", attempt.elapsedMs)
                                }
                            }
                        }
                    }
                }
            }
        }

        val text = json.encodeToString(JsonElement.serializer(), root)
        val dir = File(context.applicationContext.cacheDir, REPORTS_SUBDIR)
        if (!dir.exists() && !dir.mkdirs()) {
            throw IllegalStateException("无法创建报告缓存目录：${dir.absolutePath}")
        }
        pruneOldReports(dir)

        val stamp = SimpleDateFormat("yyyyMMdd-HHmmss-SSS", Locale.US).format(Date())
        val suffix = "%04x".format(Locale.US, random.nextInt(0x10000))
        val file = File(dir, "raincheck-report-$stamp-$suffix.json")
        file.writeText(text, Charsets.UTF_8)
        return file
    }

    fun createShareIntent(context: Context, file: File): Intent {
        val uri = FileProvider.getUriForFile(
            context,
            "${context.packageName}.fileprovider",
            file,
        )
        val sendIntent = Intent(Intent.ACTION_SEND).apply {
            type = "application/json"
            putExtra(Intent.EXTRA_STREAM, uri)
            putExtra(Intent.EXTRA_SUBJECT, "RainCheck 脱敏签到报告 (${file.name})")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        return Intent.createChooser(sendIntent, "分享脱敏签到报告")
    }

    fun sanitizeText(input: String, maxChars: Int = MAX_BODY_CHARS): String {
        var cleaned = bearerRegex.replace(input, "Bearer [REDACTED]")
        cleaned = cookieSecretRegex.replace(cleaned) { match ->
            "${match.groupValues[1]}=[REDACTED]"
        }
        return if (cleaned.length > maxChars) {
            cleaned.take(maxChars) + "…[truncated ${cleaned.length - maxChars} chars]"
        } else {
            cleaned
        }
    }

    private fun pruneOldReports(dir: File) {
        val files = dir.listFiles { f -> f.isFile && f.name.endsWith(".json") } ?: return
        if (files.size < MAX_CACHED_REPORTS) return
        files.sortedByDescending { it.lastModified() }
            .drop(MAX_CACHED_REPORTS - 1)
            .forEach { runCatching { it.delete() } }
    }
}
