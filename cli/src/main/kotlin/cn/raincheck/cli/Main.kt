package cn.raincheck.cli

import cn.raincheck.core.Account
import cn.raincheck.core.AccountRepository
import cn.raincheck.core.Edition
import cn.raincheck.core.LoginService
import cn.raincheck.core.LoginState
import cn.raincheck.core.ProtocolProfile
import cn.raincheck.core.QrParser
import cn.raincheck.core.RainCheckApi
import cn.raincheck.core.SignInEngine
import cn.raincheck.core.SignOptions
import cn.raincheck.core.SignResult
import cn.raincheck.core.SignState
import cn.raincheck.core.TicketKind
import cn.raincheck.core.nowMillis
import cn.raincheck.core.randomId
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.io.File
import java.nio.charset.StandardCharsets
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.nio.file.attribute.AclEntry
import java.nio.file.attribute.AclEntryPermission
import java.nio.file.attribute.AclEntryType
import java.nio.file.attribute.AclFileAttributeView
import java.nio.file.attribute.PosixFileAttributeView
import java.nio.file.attribute.PosixFilePermissions
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock
import kotlin.system.exitProcess

private val json = Json { prettyPrint = true; ignoreUnknownKeys = true }

private class CliUsageException(message: String, val exitCode: Int = 2) : RuntimeException(message)
private class StoreCorruptException(message: String) : RuntimeException(message)

fun main(args: Array<String>) {
    val exitCode = runBlocking { runCli(args) }
    exitProcess(exitCode)
}

internal suspend fun runCli(args: Array<String>): Int {
    if (args.isEmpty() || args[0] in setOf("-h", "--help", "help")) {
        printHelp(args.getOrNull(1))
        return 0
    }

    val command = args[0]
    val options = try {
        Options(args.drop(1))
    } catch (e: CliUsageException) {
        System.err.println(e.message)
        return e.exitCode
    }

    if (options.has("help") || options.has("h")) {
        printHelp(command)
        return 0
    }

    val profile = try {
        options.profilePath?.let { path ->
            val file = File(path)
            if (!file.exists()) throw CliUsageException("找不到协议文件: $path")
            ProtocolProfile.parse(file.readText(StandardCharsets.UTF_8))
        } ?: loadBundledProfile()
    } catch (e: CliUsageException) {
        System.err.println(e.message)
        return e.exitCode
    } catch (e: Throwable) {
        System.err.println("加载协议文件失败: ${e.message}")
        return 2
    }

    val store = Store(options.storePath)
    // 延迟初始化 HTTP 客户端：parse / accounts 等离线命令绝不启动 OkHttp 线程池
    val apiLazy = lazy { RainCheckApi(profile) }

    return try {
        when (command) {
            "parse" -> parseCommand(options, profile)
            "accounts" -> accountsCommand(options, store, profile)
            "login" -> loginCommand(options, store, profile, apiLazy.value)
            "signin" -> signinCommand(options, store, profile, apiLazy.value)
            "context" -> contextCommand(options, store, profile, apiLazy.value)
            "probe" -> probeCommand(options, store, profile, apiLazy.value)
            else -> {
                System.err.println("未知命令: $command")
                printHelp(null)
                2
            }
        }
    } catch (e: CliUsageException) {
        System.err.println(e.message)
        e.exitCode
    } catch (e: StoreCorruptException) {
        System.err.println(e.message)
        2
    } catch (e: IllegalArgumentException) {
        System.err.println("参数错误: ${e.message}")
        2
    } finally {
        if (apiLazy.isInitialized()) {
            apiLazy.value.close()
        }
    }
}

private fun printHelp(subcommand: String?) {
    when (subcommand) {
        "parse" -> println(
            """
            用法: raincheck parse <二维码文本|@文件> [--profile PATH]
                  raincheck parse --qr <二维码文本|@文件> [--profile PATH]

            说明: 解析二维码文本或文件，输出类型、主机、lessonId/classroomId 与全部参数（纯离线）。
            """.trimIndent(),
        )
        "accounts" -> println(
            """
            用法:
              raincheck accounts list [--store PATH]
              raincheck accounts import --label NAME (--token TOKEN | --token-stdin | 环境变量 RAINCHECK_TOKEN)
                                        [--sessionid SID] [--csrf CSRF] [--host HOST] [--scheme https|http] [--edition ID]
              raincheck accounts remove --id ID [--store PATH]

            说明: 管理本地账号池（纯离线，原子写盘并收紧文件权限）。
            """.trimIndent(),
        )
        "login" -> println(
            """
            用法: raincheck login [--edition ID] [--host HOST] [--scheme https|http] [--label NAME] [--timeout MS]

            说明: 发起扫码登录，轮询扫码与验证码状态，成功后写入账号池。
            """.trimIndent(),
        )
        "signin" -> println(
            """
            用法: raincheck signin --qr <二维码文本|@文件> [选项]

            选项:
              --concurrency N    并发数 1..32（默认 4）
              --retries N        单策略尝试次数 1..10（默认 3）
              --backoff MS       基础退避毫秒 0..30000（默认 800）
              --stagger MS       账号错开延迟毫秒 0..10000（默认 60）
              --dry-run          演练模式：只生成策略轨迹，不发任何网络请求
              --json PATH        输出详细 JSON 报告（自动创建父目录，不含明文凭据）
              --host HOST        临时覆盖请求主机（绝不污染落盘的 accounts.json）
              --scheme SCHEME    临时覆盖协议（https/http，绝不污染落盘的 accounts.json）
              --only A,B         仅执行指定标签的账号
              --strategy ID,ID   仅执行指定策略 ID
              --no-stop-expired  遇二维码失效不提前中止策略链
            """.trimIndent(),
        )
        "context" -> println(
            """
            用法: raincheck context [--id ACCOUNT_ID] [--store PATH] [--profile PATH]

            说明: 查询指定账号（默认第一个账号）当前进行中的课堂上下文。
            """.trimIndent(),
        )
        "probe" -> println(
            """
            用法: raincheck probe --path /api/v3/... [--method GET|POST] [--query "a=1&b=2"]
                                  [--body '{"lessonId":"1"}'] [--id ACCOUNT_ID] [--host HOST] [--scheme https|http]
                                  [--referer URL]

            说明: 原始报文实验室。指定 --id 时若账号不存在将直接报错退出，绝不静默匿名发包。
            """.trimIndent(),
        )
        else -> println(
            """
            RainCheck CLI — 雨课堂多账号扫码签到（脱离官方客户端）

            用法:
              raincheck parse <二维码文本|@文件>            解析二维码，打印类型与参数
              raincheck accounts list                      列出账号池
              raincheck accounts import --label NAME [--token TOKEN | --token-stdin] [--sessionid SID] [--csrf CSRF]
                                        [--edition ID] [--host HOST] [--scheme https|http]
              raincheck accounts remove --id ID
              raincheck login [--edition ID] [--host HOST] [--label NAME] 扫码登录并写入账号池
              raincheck context [--id ID]                  查看账号当前进行中的课堂
              raincheck probe --method POST --path /api/v3/lesson/checkin --body '{"lessonId":"1","source":1}'
                              [--id 账号ID] [--host HOST] [--query "a=b&c=d"]   原始报文实验室
              raincheck signin --qr <文本|@文件> [--concurrency 4] [--dry-run] [--json out.json]
                             [--host HOST] [--only 账号标签,标签] [--strategy ID,ID]

            公共参数:
              --store PATH     账号池文件（默认 ~/.raincheck/accounts.json）
              --profile PATH   协议描述文件（默认使用内置 protocol/profile.json）
              --help / -h      查看总体或子命令帮助（如 `raincheck signin --help`）
            """.trimIndent(),
        )
    }
}

private fun parseCommand(options: Options, profile: ProtocolProfile): Int {
    val raw = options.value("qr") ?: options.positional.firstOrNull()
        ?: throw CliUsageException("缺少二维码文本（请传入位置参数或 --qr）")
    val ticket = QrParser.parse(readQr(raw), profile)
    println("类型     : ${ticket.kind}")
    println("原始     : ${ticket.raw}")
    println("host     : ${ticket.host ?: "-"}")
    println("lessonId : ${ticket.lessonId ?: "-"}")
    println("classroom: ${ticket.classroomId ?: "-"}")
    println("checkinId: ${ticket.checkinId ?: "-"}")
    println("参数     : ${ticket.params}")
    ticket.url?.let { url ->
        val blockReason = profile.validateQrUrl(url)
        if (blockReason != null) {
            println("安全警告 : 二维码 URL 未通过白名单校验（$blockReason），引擎不会向其发送凭据")
        }
    }
    if (ticket.kind == TicketKind.DYNAMIC_CHECKIN) {
        println("提示     : 动态码有效期很短，多账号请直接 signin 并发提交")
    }
    return 0
}

private fun accountsCommand(options: Options, store: Store, profile: ProtocolProfile): Int {
    val action = options.positional.firstOrNull() ?: "list"
    when (action) {
        "list" -> {
            val accounts = store.load()
            if (accounts.isEmpty()) {
                println("账号池为空。用 accounts import 或 login 添加。")
                return 0
            }
            println(String.format("%-38s %-12s %-22s %-6s %s", "ID", "标签", "站点", "启用", "凭据"))
            accounts.forEach { a ->
                println(
                    String.format(
                        "%-38s %-12s %-22s %-6s %s",
                        a.id,
                        a.label,
                        "${a.scheme}://${a.host}",
                        if (a.enabled) "是" else "否",
                        a.maskedCredential(),
                    ),
                )
            }
            return 0
        }
        "import" -> {
            val existing = store.load()
            val label = options.value("label") ?: "账号${existing.size + 1}"
            val edition = resolveEdition(options, profile)
            val rawToken = resolveTokenInput(options)
            val token = rawToken?.let { stripBearerPrefix(it, profile) }?.takeIf { it.isNotBlank() }
            val sessionId = (options.value("sessionid") ?: options.value("sid") ?: System.getenv("RAINCHECK_SESSIONID"))
                ?.trim()?.takeIf { it.isNotBlank() }
            val csrf = (options.value("csrf") ?: System.getenv("RAINCHECK_CSRF"))
                ?.trim()?.takeIf { it.isNotBlank() }

            if (token.isNullOrBlank() && sessionId.isNullOrBlank()) {
                throw CliUsageException("需要提供凭据：--token / --token-stdin / 环境变量 RAINCHECK_TOKEN 或 --sessionid")
            }
            val account = Account(
                id = randomId(),
                label = label,
                host = edition.host,
                scheme = edition.scheme,
                bearer = token,
                sessionId = sessionId,
                csrfToken = csrf,
                createdAt = nowMillis(),
            )
            store.upsert(account)
            println("已写入账号池: ${account.label} (${account.id}) -> ${account.scheme}://${account.host}")
            return 0
        }
        "remove" -> {
            val id = options.value("id") ?: options.positional.getOrNull(1)
                ?: throw CliUsageException("需要 --id")
            store.remove(id)
            println("已移除 $id")
            return 0
        }
        else -> throw CliUsageException("未知 accounts 子命令: $action")
    }
}

private suspend fun loginCommand(
    options: Options,
    store: Store,
    profile: ProtocolProfile,
    api: RainCheckApi,
): Int {
    val edition = resolveEdition(options, profile)
    val label = options.value("label") ?: "账号${store.load().size + 1}"
    val service = LoginService(api, profile)

    val start = service.start(edition)
    if (start.state != LoginState.PENDING) {
        System.err.println("发起登录失败: ${start.message}")
        return 1
    }
    println("站点: ${edition.label} (${edition.baseUrl})")
    println("请用「$label」对应的微信扫描以下二维码内容：")
    println(start.qrContent)
    println("（把这段内容渲染成二维码即可；终端环境下也可粘贴到任意二维码生成器）")

    val timeoutMs = options.value("timeout")?.let { raw ->
        raw.toLongOrNull()?.takeIf { it > 0 }
            ?: throw CliUsageException("--timeout 必须为正整数毫秒: $raw")
    } ?: 300_000L
    val deadline = nowMillis() + timeoutMs
    var token = start.loginToken ?: return 1

    while (nowMillis() < deadline) {
        delay(2_000)
        val poll = service.poll(edition, token)
        when (poll.state) {
            LoginState.PENDING -> {
                println("[等待] ${poll.message}")
            }
            LoginState.SCANNED -> {
                println("[已扫码] ${poll.message}")
            }
            LoginState.NEED_CODE -> {
                var verifyToken = poll.loginToken ?: token
                var codeAttempts = 0
                while (codeAttempts < 5 && nowMillis() < deadline) {
                    print("需要 4 位验证码: ")
                    val code = readlnOrNull()?.trim().orEmpty()
                    if (code.isEmpty()) {
                        System.err.println("已取消输入验证码")
                        return 1
                    }
                    val after = service.submitCode(edition, verifyToken, code)
                    when (after.state) {
                        LoginState.AUTHORIZED -> {
                            val authorized = after.account
                                ?: run {
                                    System.err.println("登录返回成功但缺少账号凭据")
                                    return 1
                                }
                            store.upsert(authorized.copy(id = randomId(), label = label))
                            println("登录成功，已写入账号池: $label (${authorized.userId ?: "uid?"})")
                            return 0
                        }
                        LoginState.NEED_CODE -> {
                            verifyToken = after.loginToken ?: verifyToken
                            codeAttempts++
                            println("[验证码未通过] ${after.message}")
                        }
                        LoginState.EXPIRED -> {
                            System.err.println("二维码已失效: ${after.message}")
                            return 1
                        }
                        else -> {
                            System.err.println("提交验证码异常: ${after.message}")
                            return 1
                        }
                    }
                }
                System.err.println("验证码重试次数已达上限或已超时")
                return 1
            }
            LoginState.AUTHORIZED -> {
                val account = poll.account ?: run {
                    System.err.println("登录响应成功但未获取到凭据")
                    return 1
                }
                store.upsert(account.copy(id = randomId(), label = label))
                println("登录成功，已写入账号池: $label (${account.userId ?: "uid?"})")
                return 0
            }
            LoginState.EXPIRED -> {
                System.err.println("二维码已失效: ${poll.message}")
                return 1
            }
            LoginState.ERROR -> {
                System.err.println("登录异常: ${poll.message}")
                return 1
            }
        }
    }
    System.err.println("等待扫码超时")
    return 1
}

private suspend fun probeCommand(
    options: Options,
    store: Store,
    profile: ProtocolProfile,
    api: RainCheckApi,
): Int {
    val method = (options.value("method") ?: "GET").uppercase()
    val path = options.value("path") ?: options.positional.firstOrNull()
        ?: throw CliUsageException("需要 --path /api/v3/...")

    val accountId = options.value("id")
    val account = if (accountId != null) {
        store.load().firstOrNull { it.id == accountId }
            ?: throw CliUsageException("找不到账号 ID: $accountId（已中止，不会匿名发包）")
    } else {
        null
    }

    val defaultEdition = profile.defaultEditionSpec()
    val hostOpt = options.value("host")
    val schemeOpt = options.value("scheme")
    val resolvedHost = hostOpt ?: account?.host ?: defaultEdition.host
    val resolvedScheme = schemeOpt
        ?: (if (hostOpt != null) profile.editionForHost(hostOpt)?.scheme else account?.scheme)
        ?: defaultEdition.scheme

    val url = api.buildUrl(
        "$resolvedScheme://$resolvedHost",
        path,
        Options.parseQuery(options.value("query")),
    )
    val body = options.value("body")?.let { raw ->
        runCatching {
            Json.parseToJsonElement(raw).let {
                it as? JsonObject ?: error("body 必须是 JSON 对象")
            }
        }.getOrElse { error ->
            throw CliUsageException("body 解析失败: ${error.message}")
        }
    }
    println("$method $url")
    body?.let { println("body: $it") }
    val result = api.raw(
        account = account,
        method = method,
        url = url,
        body = body,
        referer = options.value("referer"),
    )
    println("HTTP ${result.httpStatus}  code=${result.code ?: "-"}  ${result.elapsedMs} ms")
    println(result.body.take(4000))
    result.auth?.let { auth ->
        val updatedKinds = buildList {
            if (!auth.bearer.isNullOrBlank()) add("bearer(已脱敏)")
            if (!auth.sessionId.isNullOrBlank()) add("sessionid(已脱敏)")
            if (!auth.csrfToken.isNullOrBlank()) add("csrftoken(已脱敏)")
        }
        if (updatedKinds.isNotEmpty()) {
            println("会话回填: ${updatedKinds.joinToString(", ")}")
        }
    }
    return if (result.httpStatus < 0 || result.httpStatus >= 400) 1 else 0
}

private suspend fun contextCommand(
    options: Options,
    store: Store,
    profile: ProtocolProfile,
    api: RainCheckApi,
): Int {
    val all = store.load()
    val requestedId = options.value("id")
    val account = if (requestedId != null) {
        all.firstOrNull { it.id == requestedId }
            ?: throw CliUsageException("找不到账号: $requestedId")
    } else {
        all.firstOrNull() ?: throw CliUsageException("账号池为空，无法查询课堂上下文")
    }
    val engine = SignInEngine(
        api = api,
        profile = profile,
        onAccountUpdated = { updated -> store.updateCredentialsPreservingHost(updated) },
    )
    val context = engine.discover(account)
    if (context == null) {
        println("没有进行中的课堂（或接口返回结构变化）")
    } else {
        println("进行中课堂: ${context.display()}  lessonId=${context.lessonId} classroomId=${context.classroomId ?: "-"}")
    }
    return 0
}

private suspend fun signinCommand(
    options: Options,
    store: Store,
    profile: ProtocolProfile,
    api: RainCheckApi,
): Int {
    val rawQr = options.value("qr") ?: options.positional.firstOrNull()
        ?: throw CliUsageException("需要 --qr <二维码文本|@文件>")
    val ticket = QrParser.parse(readQr(rawQr), profile)

    val hostOverride = options.value("host")
    val schemeOverride = options.value("scheme")
    val storedAccounts = store.load()
    var accounts = storedAccounts
    if (hostOverride != null || schemeOverride != null) {
        accounts = accounts.map { acc ->
            val targetHost = hostOverride ?: acc.host
            val targetScheme = schemeOverride
                ?: (if (hostOverride != null) profile.editionForHost(hostOverride)?.scheme else null)
                ?: acc.scheme
            acc.copy(host = targetHost, scheme = targetScheme)
        }
    }
    options.value("only")?.split(',')?.map { it.trim() }?.filter { it.isNotEmpty() }?.let { labels ->
        accounts = accounts.filter { labels.contains(it.label) }
    }
    if (accounts.isEmpty()) {
        throw CliUsageException("账号池为空（或 --only 未匹配到任何账号），无法签到")
    }

    val concurrency = parseIntOption(options, "concurrency", defaultValue = 4, range = 1..32)
    val retries = parseIntOption(options, "retries", defaultValue = 3, range = 1..10)
    val backoffMs = parseLongOption(options, "backoff", defaultValue = 800L, range = 0L..30_000L)
    val staggerMs = parseLongOption(options, "stagger", defaultValue = 60L, range = 0L..10_000L)

    val signOptions = SignOptions(
        concurrency = concurrency,
        maxAttemptsPerStrategy = retries,
        baseBackoffMs = backoffMs,
        stopWhenTicketExpired = !options.has("no-stop-expired"),
        dryRun = options.has("dry-run"),
        strategyIds = options.value("strategy")?.split(',')?.map { it.trim() }?.filter { it.isNotEmpty() },
        staggerMs = staggerMs,
    )

    println("二维码: ${ticket.summary()}")
    println("账号数: ${accounts.count { it.enabled }} / 并发: ${signOptions.concurrency}${if (signOptions.dryRun) " [演练模式]" else ""}")

    val engine = SignInEngine(
        api = api,
        profile = profile,
        onAccountUpdated = { updated ->
            // 仅回填会话凭据与活跃时间，绝不让 --host / --scheme 临时覆盖污染落盘账号池
            store.updateCredentialsPreservingHost(updated)
        },
        log = { println("  · $it") },
    )
    val report = engine.signInAll(accounts, ticket, signOptions)

    println()
    println(String.format("%-4s %-14s %-12s %-18s %s", "  ", "账号", "状态", "策略", "消息"))
    report.results.forEach { r ->
        val badge = when {
            r.ok -> "OK"
            r.state == SignState.DRY_RUN -> "DRY"
            else -> "NG"
        }
        println(
            String.format(
                "%-4s %-14s %-12s %-18s %s",
                badge,
                r.label,
                stateLabel(r.state),
                r.strategy ?: "-",
                r.message.take(60),
            ),
        )
    }
    println()
    if (report.dryRunCount > 0) {
        println("成功 ${report.successCount} / 演练 ${report.dryRunCount} / 失败 ${report.failedCount} / 耗时 ${report.elapsedMs} ms")
    } else {
        println("成功 ${report.successCount} / 失败 ${report.failedCount} / 耗时 ${report.elapsedMs} ms")
    }

    options.value("json")?.let { path ->
        val outFile = File(path)
        outFile.parentFile?.mkdirs()
        outFile.writeText(renderReportJson(report.results), StandardCharsets.UTF_8)
        println("明细已写入 $path")
    }

    return if (report.failedCount > 0) 1 else 0
}

private fun resolveEdition(options: Options, profile: ProtocolProfile): Edition {
    val editionId = options.value("edition")
    val hostOpt = options.value("host")
    val schemeOpt = options.value("scheme")

    val base = when {
        editionId != null -> profile.edition(editionId)
            ?: throw CliUsageException("未知站点 ID: $editionId（可选: ${profile.editions.joinToString { it.id }}）")
        hostOpt != null -> profile.editionForHost(hostOpt) ?: Edition.fromHost(hostOpt, schemeOpt)
        else -> profile.defaultEditionSpec()
    }
    val finalHost = hostOpt ?: base.host
    val finalScheme = schemeOpt?.lowercase() ?: base.scheme
    if (finalScheme != "https" && finalScheme != "http") {
        throw CliUsageException("--scheme 仅支持 https 或 http，收到: $finalScheme")
    }
    return base.copy(host = finalHost, scheme = finalScheme)
}

private fun resolveTokenInput(options: Options): String? {
    if (options.has("token-stdin")) {
        return System.`in`.bufferedReader(StandardCharsets.UTF_8).readText().trim().takeIf { it.isNotBlank() }
    }
    return (options.value("token") ?: options.value("bearer") ?: System.getenv("RAINCHECK_TOKEN"))
        ?.trim()?.takeIf { it.isNotBlank() }
}

private fun stripBearerPrefix(raw: String, profile: ProtocolProfile): String {
    val trimmed = raw.trim()
    val prefix = profile.auth.bearerPrefix
    if (prefix.isNotEmpty() && trimmed.startsWith(prefix, ignoreCase = true)) {
        return trimmed.substring(prefix.length).trim()
    }
    val trimmedPrefix = prefix.trim()
    if (trimmedPrefix.isNotEmpty() && trimmed.startsWith("$trimmedPrefix ", ignoreCase = true)) {
        return trimmed.substring(trimmedPrefix.length + 1).trim()
    }
    return trimmed
}

private fun parseIntOption(options: Options, name: String, defaultValue: Int, range: IntRange): Int {
    val raw = options.value(name) ?: return defaultValue
    val parsed = raw.toIntOrNull()
        ?: throw CliUsageException("--$name 必须是整数（${range.first}..${range.last}），收到: $raw")
    if (parsed !in range) {
        throw CliUsageException("--$name 超出允许范围 ${range.first}..${range.last}，收到: $parsed")
    }
    return parsed
}

private fun parseLongOption(options: Options, name: String, defaultValue: Long, range: LongRange): Long {
    val raw = options.value(name) ?: return defaultValue
    val parsed = raw.toLongOrNull()
        ?: throw CliUsageException("--$name 必须是整数（${range.first}..${range.last}），收到: $raw")
    if (parsed !in range) {
        throw CliUsageException("--$name 超出允许范围 ${range.first}..${range.last}，收到: $parsed")
    }
    return parsed
}

private fun renderReportJson(results: List<SignResult>): String = json.encodeToString(
    JsonElement.serializer(),
    buildJsonObject {
        put(
            "results",
            buildJsonArray {
                results.forEach { r ->
                    add(
                        buildJsonObject {
                            put("accountId", r.accountId)
                            put("label", r.label)
                            put("state", r.state.name)
                            put("ok", r.ok)
                            put("strategy", r.strategy ?: "")
                            put("lessonId", r.lessonId ?: "")
                            put("message", r.message)
                            put(
                                "attempts",
                                buildJsonArray {
                                    r.attempts.forEach { a ->
                                        add(
                                            buildJsonObject {
                                                put("strategy", a.strategy)
                                                put("httpStatus", a.httpStatus ?: 0)
                                                put("code", a.code ?: -1)
                                                put("ok", a.ok)
                                                put("message", a.message ?: "")
                                                put("request", a.requestLine)
                                                put("requestBody", a.requestBody ?: "")
                                                put("response", a.responseBody ?: "")
                                                put("elapsedMs", a.elapsedMs)
                                            },
                                        )
                                    }
                                },
                            )
                        },
                    )
                }
            },
        )
    },
)

private fun stateLabel(state: SignState): String = when (state) {
    SignState.SUCCESS -> "成功"
    SignState.ALREADY -> "已签到"
    SignState.DRY_RUN -> "演练"
    SignState.FAILED -> "失败"
    SignState.AUTH_REQUIRED -> "需重新登录"
    SignState.TICKET_EXPIRED -> "二维码过期"
    SignState.NO_CONTEXT -> "缺课堂上下文"
    SignState.ERROR -> "异常"
}

private fun readQr(value: String): String {
    val text = if (value.startsWith("@")) {
        val file = File(value.drop(1))
        if (!file.exists()) throw CliUsageException("找不到二维码文件: ${file.path}")
        file.readText(StandardCharsets.UTF_8)
    } else {
        value
    }
    return text.trim()
}

private fun loadBundledProfile(): ProtocolProfile {
    val stream = Thread.currentThread().contextClassLoader.getResourceAsStream("profile.json")
        ?: object {}.javaClass.getResourceAsStream("/profile.json")
        ?: error("找不到内置 profile.json")
    return ProtocolProfile.parse(stream.bufferedReader(StandardCharsets.UTF_8).use { it.readText() })
}

/**
 * 线程安全、原子落盘且收紧访问权限的本地账号仓库。
 *
 * - 使用 [ReentrantLock] 保证并发读-改-写互斥；
 * - 写入时先写同目录临时文件、收紧 POSIX `0600` 或 Windows 当前用户 ACL，再原子替换目标文件；
 * - 文件损坏时备份原文件并抛出 [StoreCorruptException]，绝不静默清空全部账号。
 */
internal class Store(private val path: File) : AccountRepository {
    private val lock = ReentrantLock()
    private val listSerializer = ListSerializer(Account.serializer())

    override fun load(): List<Account> = lock.withLock { loadLocked() }

    override fun save(accounts: List<Account>) = lock.withLock { saveLocked(accounts) }

    override fun upsert(account: Account) = lock.withLock {
        val list = loadLocked().toMutableList()
        val index = list.indexOfFirst { it.id == account.id }
        if (index >= 0) list[index] = account else list.add(account)
        saveLocked(list)
    }

    override fun remove(id: String) = lock.withLock {
        saveLocked(loadLocked().filterNot { it.id == id })
    }

    /** 仅更新已存在账号的会话材料与活跃时间戳，保留落盘的 host/scheme/enabled 等原始配置。 */
    fun updateCredentialsPreservingHost(refreshed: Account) = lock.withLock {
        val list = loadLocked().toMutableList()
        val index = list.indexOfFirst { it.id == refreshed.id }
        if (index < 0) return@withLock
        val original = list[index]
        val merged = original.copy(
            bearer = refreshed.bearer?.takeIf { it.isNotBlank() } ?: original.bearer,
            sessionId = refreshed.sessionId?.takeIf { it.isNotBlank() } ?: original.sessionId,
            csrfToken = refreshed.csrfToken?.takeIf { it.isNotBlank() } ?: original.csrfToken,
            lastOkAt = refreshed.lastOkAt ?: original.lastOkAt,
            userId = refreshed.userId ?: original.userId,
        )
        if (merged != original) {
            list[index] = merged
            saveLocked(list)
        }
    }

    private fun loadLocked(): List<Account> {
        if (!path.exists()) return emptyList()
        val content = path.readText(StandardCharsets.UTF_8)
        if (content.isBlank()) return emptyList()
        return try {
            json.decodeFromString(listSerializer, content)
        } catch (e: Throwable) {
            val backup = File(path.parentFile, "${path.name}.corrupt-${nowMillis()}.bak")
            runCatching { Files.copy(path.toPath(), backup.toPath(), StandardCopyOption.REPLACE_EXISTING) }
            throw StoreCorruptException(
                "账号池文件 ${path.path} JSON 解析失败（已备份原文件至 ${backup.path}，未清空数据）: ${e.message}",
            )
        }
    }

    private fun saveLocked(accounts: List<Account>) {
        val parentDir = path.absoluteFile.parentFile ?: File(".")
        if (!parentDir.exists()) {
            parentDir.mkdirs()
            restrictDirectoryPermissions(parentDir.toPath())
        }
        val payload = json.encodeToString(listSerializer, accounts)
        val tempFile = Files.createTempFile(parentDir.toPath(), ".accounts-", ".tmp")
        try {
            Files.writeString(tempFile, payload, StandardCharsets.UTF_8)
            restrictFilePermissions(tempFile)
            try {
                Files.move(
                    tempFile,
                    path.toPath(),
                    StandardCopyOption.ATOMIC_MOVE,
                    StandardCopyOption.REPLACE_EXISTING,
                )
            } catch (_: AtomicMoveNotSupportedException) {
                Files.move(tempFile, path.toPath(), StandardCopyOption.REPLACE_EXISTING)
            }
            restrictFilePermissions(path.toPath())
        } catch (t: Throwable) {
            runCatching { Files.deleteIfExists(tempFile) }
            throw t
        }
    }

    private fun restrictFilePermissions(target: Path) {
        runCatching {
            val posix = Files.getFileAttributeView(target, PosixFileAttributeView::class.java)
            if (posix != null) {
                Files.setPosixFilePermissions(target, PosixFilePermissions.fromString("rw-------"))
                return
            }
            val aclView = Files.getFileAttributeView(target, AclFileAttributeView::class.java)
            if (aclView != null) {
                val owner = Files.getOwner(target)
                val entry = AclEntry.newBuilder()
                    .setType(AclEntryType.ALLOW)
                    .setPrincipal(owner)
                    .setPermissions(
                        AclEntryPermission.READ_DATA,
                        AclEntryPermission.WRITE_DATA,
                        AclEntryPermission.APPEND_DATA,
                        AclEntryPermission.READ_NAMED_ATTRS,
                        AclEntryPermission.WRITE_NAMED_ATTRS,
                        AclEntryPermission.READ_ATTRIBUTES,
                        AclEntryPermission.WRITE_ATTRIBUTES,
                        AclEntryPermission.DELETE,
                        AclEntryPermission.READ_ACL,
                        AclEntryPermission.WRITE_ACL,
                        AclEntryPermission.SYNCHRONIZE,
                    )
                    .build()
                aclView.acl = listOf(entry)
            }
        }
    }

    private fun restrictDirectoryPermissions(dir: Path) {
        runCatching {
            val posix = Files.getFileAttributeView(dir, PosixFileAttributeView::class.java)
            if (posix != null) {
                Files.setPosixFilePermissions(dir, PosixFilePermissions.fromString("rwx------"))
            }
        }
    }
}

internal class Options(args: List<String>) {
    private val flags = mutableMapOf<String, String>()
    private val booleans = mutableSetOf<String>()
    val positional = mutableListOf<String>()

    init {
        var i = 0
        var endOfFlags = false
        while (i < args.size) {
            val arg = args[i]
            if (endOfFlags) {
                positional += arg
                i++
                continue
            }
            if (arg == "--") {
                endOfFlags = true
                i++
                continue
            }
            if (arg == "-h" || arg == "--help") {
                booleans += "help"
                i++
                continue
            }
            if (arg.startsWith("--") && arg.length > 2) {
                val body = arg.removePrefix("--")
                val eqIdx = body.indexOf('=')
                if (eqIdx > 0) {
                    val name = body.substring(0, eqIdx)
                    val value = body.substring(eqIdx + 1)
                    if (name in BOOLEAN_FLAGS) {
                        if (value.equals("true", ignoreCase = true) || value == "1") {
                            booleans += name
                        } else if (value.equals("false", ignoreCase = true) || value == "0") {
                            booleans -= name
                        } else {
                            throw CliUsageException("布尔选项 --$name 不支持的值: $value")
                        }
                    } else {
                        flags[name] = value
                    }
                    i++
                } else if (body in BOOLEAN_FLAGS) {
                    booleans += body
                    i++
                } else {
                    val next = args.getOrNull(i + 1)
                    if (next == null || next.startsWith("--") || next == "-h") {
                        throw CliUsageException("选项 --$body 缺少参数值")
                    }
                    flags[body] = next
                    i += 2
                }
            } else {
                positional += arg
                i++
            }
        }
    }

    val storePath: File
        get() = File(
            flags["store"]
                ?: File(System.getProperty("user.home"), ".raincheck/accounts.json").path,
        )

    val profilePath: String? get() = flags["profile"]

    fun value(name: String): String? = flags[name]?.takeIf { it.isNotBlank() }

    fun has(name: String): Boolean = name in booleans || flags.containsKey(name)

    companion object {
        private val BOOLEAN_FLAGS = setOf(
            "dry-run",
            "token-stdin",
            "no-stop-expired",
            "help",
            "h",
        )

        fun parseQuery(raw: String?): Map<String, String> =
            if (raw.isNullOrBlank()) emptyMap() else QrParser.queryOf(raw)
    }
}
