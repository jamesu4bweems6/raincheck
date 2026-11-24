package cn.raincheck.core

import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.request.HttpRequestData
import io.ktor.http.Headers
import io.ktor.http.HeadersBuilder
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.utils.io.ByteReadChannel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SignInEngineTest {

    private val profile: ProtocolProfile = ProtocolProfile.parse(readProtocolFile("profile.json"))

    private data class MockReply(
        val status: Int,
        val body: String,
        val headers: List<Pair<String, String>> = emptyList(),
        val contentType: String = "application/json",
    )

    private fun api(
        engine: MockEngine,
        customProfile: ProtocolProfile = profile,
    ): RainCheckApi = RainCheckApi(customProfile, HttpClient(engine) { expectSuccess = false })

    private fun mock(responder: (HttpRequestData) -> MockReply): MockEngine =
        MockEngine { request ->
            val reply = responder(request)
            val builtHeaders: Headers = HeadersBuilder().apply {
                append(HttpHeaders.ContentType, reply.contentType)
                reply.headers.forEach { (k, v) -> append(k, v) }
            }.build()
            respond(
                content = ByteReadChannel(reply.body),
                status = HttpStatusCode.fromValue(reply.status),
                headers = builtHeaders,
            )
        }

    private fun simpleMock(
        headers: List<Pair<String, String>> = emptyList(),
        responder: (HttpRequestData) -> Pair<Int, String>,
    ): MockEngine = mock { req ->
        val (status, body) = responder(req)
        MockReply(status = status, body = body, headers = headers)
    }

    private val account = Account(
        id = "a1",
        label = "张三",
        host = "www.yuketang.cn",
        scheme = "https",
        bearer = "token-1",
    )

    private fun bodyOf(request: HttpRequestData): String =
        runCatching { (request.body as io.ktor.http.content.TextContent).text }.getOrElse { "" }

    @Test
    fun `静态码走 LESSON_DESKTOP 成功`() = runTest {
        val engine = simpleMock { request ->
            when (request.url.encodedPath) {
                "/api/v3/lesson/checkin" -> 200 to """{"code":0,"msg":"签到成功","data":{}}"""
                else -> 404 to """{"code":40400,"msg":"no"}"""
            }
        }
        val signEngine = SignInEngine(api(engine), profile)
        val result = signEngine.signIn(account, QrParser.parse("1529274209982060032", profile))
        assertEquals(SignState.SUCCESS, result.state)
        assertEquals("LESSON_DESKTOP", result.strategy)
        assertTrue(result.ok)
    }

    @Test
    fun `动态码真实触发策略回退 DYN_TICKET_14 失败后回退到 DYN_TICKET_5 成功`() = runTest {
        val seenBodies = mutableListOf<String>()
        val engine = simpleMock { request ->
            val body = bodyOf(request)
            seenBodies += body
            when {
                request.url.encodedPath != "/api/v3/lesson/checkin" -> 404 to """{"code":40400}"""
                body.contains("\"source\":14") -> 200 to """{"code":40002,"msg":"桌面端来源被禁用"}"""
                body.contains("\"source\":5") -> 200 to """{"code":0,"msg":"签到成功"}"""
                else -> 200 to """{"code":40002,"msg":"拒绝"}"""
            }
        }
        val signEngine = SignInEngine(api(engine), profile)
        val ticket = QrParser.parse("c=abc&t=1763900000&s=sig&v=2&lessonId=999", profile)
        val result = signEngine.signIn(account, ticket)
        assertEquals(SignState.SUCCESS, result.state)
        assertEquals("DYN_TICKET_5", result.strategy)
        assertEquals(2, seenBodies.size, "必须真实触发策略链回退（至少 2 次请求）")
        assertEquals(2, result.attempts.size)
        assertEquals("DYN_TICKET_14", result.attempts[0].strategy)
        assertEquals("DYN_TICKET_5", result.attempts[1].strategy)
    }

    @Test
    fun `QR_URL 恶意第三方域名绝对拦截且零外发凭据零吸收响应头`() = runTest {
        var evilRequests = 0
        val updates = mutableListOf<Account>()
        val engine = mock { request ->
            if (request.url.host.equals("evil.example", ignoreCase = true)) {
                evilRequests++
                MockReply(
                    status = 200,
                    body = """{"code":0,"msg":"stolen"}""",
                    headers = listOf("set-auth" to "Bearer poisoned-token"),
                )
            } else {
                MockReply(status = 200, body = """{"code":40002,"msg":"策略不匹配"}""")
            }
        }
        val signEngine = SignInEngine(api(engine), profile, onAccountUpdated = { updates += it })
        val maliciousQr = QrParser.parse(
            "https://evil.example/steal?c=bad&t=1763900000&s=sig&lessonId=1001",
            profile,
        )
        val result = signEngine.signIn(account, maliciousQr)
        assertEquals(0, evilRequests, "绝不允许向第三方域名发起任何请求")
        assertTrue(updates.isEmpty(), "绝不允许吸收第三方响应头")
        assertEquals(SignState.FAILED, result.state)
        assertTrue(result.attempts.any { it.strategy == "QR_URL_POST" && it.message?.contains("安全拦截") == true })
        assertTrue(result.attempts.any { it.strategy == "QR_URL_GET" && it.message?.contains("安全拦截") == true })
    }

    @Test
    fun `QR_URL 禁止 HTTPS 站点降级为明文 HTTP`() = runTest {
        var httpCalls = 0
        val engine = simpleMock { request ->
            if (request.url.protocol.name == "http") {
                httpCalls++
            }
            200 to """{"code":40002,"msg":"策略不匹配"}"""
        }
        val signEngine = SignInEngine(api(engine), profile)
        val downgradeQr = QrParser.parse(
            "http://www.yuketang.cn/api/v3/lesson/checkin?c=abc&t=1&s=sig&lessonId=1",
            profile,
        )
        val result = signEngine.signIn(account, downgradeQr)
        assertEquals(0, httpCalls, "禁止向 HTTPS 站点降级发送明文 HTTP")
        assertTrue(result.attempts.any { it.strategy == "QR_URL_POST" && it.message?.contains("安全拦截") == true })
    }

    @Test
    fun `无 lessonId 且 discover 无结果但存在合法同源 QR_URL 策略时不误拦截`() = runTest {
        val paths = mutableListOf<String>()
        val engine = simpleMock { request ->
            paths += "${request.method.value} ${request.url.encodedPath}"
            when (request.url.encodedPath) {
                "/api/v3/classroom/on-lesson-upcoming-exam" ->
                    200 to """{"code":0,"data":{"onLessonClassrooms":[]}}"""
                "/api/v3/custom/qr-checkin" ->
                    200 to """{"code":0,"msg":"签到成功"}"""
                else -> 404 to """{"code":40400}"""
            }
        }
        val signEngine = SignInEngine(api(engine), profile)
        val ticket = QrParser.parse("https://www.yuketang.cn/api/v3/custom/qr-checkin?c=abc&t=1&s=sig", profile)
        val result = signEngine.signIn(account, ticket)
        assertEquals(SignState.SUCCESS, result.state)
        assertEquals("QR_URL_POST", result.strategy)
        assertTrue(paths.contains("POST /api/v3/custom/qr-checkin"))
    }

    @Test
    fun `code 为 0 且命中 alreadyKeywords 判 ALREADY 而签到成功判 SUCCESS`() = runTest {
        val alreadyEngine = simpleMock { 200 to """{"code":0,"msg":"已签到","data":{"signed":true}}""" }
        val rAlready = SignInEngine(api(alreadyEngine), profile)
            .signIn(account, QrParser.parse("lessonId=1", profile))
        assertEquals(SignState.ALREADY, rAlready.state)
        assertTrue(rAlready.ok)

        val successEngine = simpleMock { 200 to """{"code":0,"msg":"签到成功","data":{"signed":true}}""" }
        val rSuccess = SignInEngine(api(successEngine), profile)
            .signIn(account, QrParser.parse("lessonId=1", profile))
        assertEquals(SignState.SUCCESS, rSuccess.state)
        assertTrue(rSuccess.ok)
    }

    @Test
    fun `JsonNull 字段不会污染 msg 或 lessonId`() = runTest {
        val engine = simpleMock { request ->
            when (request.url.encodedPath) {
                "/api/v3/classroom/on-lesson-upcoming-exam" ->
                    200 to """{"code":0,"msg":null,"data":{"onLessonClassrooms":[{"lessonId":null,"lesson_id":"777","classroomId":null,"classroom_id":"88","courseName":null,"name":"高等数学"}]}}"""
                "/api/v3/lesson/checkin" ->
                    200 to """{"code":0,"msg":null,"message":"已签到","data":null}"""
                else -> 404 to """{"code":40400}"""
            }
        }
        val signEngine = SignInEngine(api(engine), profile)
        val result = signEngine.signIn(account, QrParser.parse("c=a&t=1&s=sig", profile))
        assertEquals(SignState.ALREADY, result.state)
        assertEquals("777", result.lessonId)
        assertEquals("已签到", result.message)
    }

    @Test
    fun `旧版 errcode errmsg 与自定义 okCodes 正常生效`() = runTest {
        val legacyEngine = simpleMock { 200 to """{"errcode":0,"errmsg":"重复签到"}""" }
        val r1 = SignInEngine(api(legacyEngine), profile)
            .signIn(account, QrParser.parse("lessonId=10", profile))
        assertEquals(SignState.ALREADY, r1.state)

        val customProfile = profile.copy(result = profile.result.copy(okCodes = listOf(0, 200)))
        val customCodeEngine = simpleMock { 200 to """{"errcode":200,"errmsg":"ok"}""" }
        val r2 = SignInEngine(api(customCodeEngine, customProfile), customProfile)
            .signIn(account, QrParser.parse("lessonId=10", customProfile))
        assertEquals(SignState.SUCCESS, r2.state)
    }

    @Test
    fun `会话回填立即更新 current 并传递给后续策略且失败响应不刷 lastOkAt`() = runTest {
        val authHeadersSeen = mutableListOf<String?>()
        val cookieHeadersSeen = mutableListOf<String?>()
        val updates = mutableListOf<Account>()

        val engine = mock { request ->
            authHeadersSeen += request.headers[HttpHeaders.Authorization]
            cookieHeadersSeen += request.headers[HttpHeaders.Cookie]
            val body = bodyOf(request)
            if (body.contains("\"source\":14")) {
                MockReply(
                    status = 200,
                    body = """{"code":40002,"msg":"换小程序来源"}""",
                    headers = listOf(
                        "set-auth" to "bearer rotated-token-2",
                        "authorization" to "Bearer lower-priority-token",
                        "Set-Cookie" to "sessionid=sid-rotated-2; Path=/; HttpOnly",
                        "Set-Cookie" to "csrftoken=csrf-rotated-2; Path=/",
                    ),
                )
            } else {
                MockReply(status = 200, body = """{"code":0,"msg":"签到成功"}""")
            }
        }
        val signEngine = SignInEngine(api(engine), profile, onAccountUpdated = { updates += it })
        val result = signEngine.signIn(
            account.copy(lastOkAt = null),
            QrParser.parse("c=abc&t=1&s=sig&lessonId=1", profile),
        )
        assertEquals(SignState.SUCCESS, result.state)
        assertEquals("DYN_TICKET_5", result.strategy)
        assertEquals(listOf<String?>("Bearer token-1", "Bearer rotated-token-2"), authHeadersSeen)
        assertEquals("sessionid=sid-rotated-2; csrftoken=csrf-rotated-2", cookieHeadersSeen[1])
        assertEquals(1, updates.size)
        assertEquals("rotated-token-2", updates[0].bearer)
        assertEquals("sid-rotated-2", updates[0].sessionId)
        assertEquals("csrf-rotated-2", updates[0].csrfToken)
        assertNull(updates[0].lastOkAt, "失败策略产生的凭据回填不应误刷 lastOkAt")
    }

    @Test
    fun `忽略空值与过期清 Cookie 响应头且验证 Header 优先级与去重`() = runTest {
        var capturedContentTypeCount = 0
        var capturedXtbzValues: List<String> = emptyList()
        val updates = mutableListOf<Account>()

        val engine = mock { request ->
            capturedContentTypeCount = request.headers.getAll(HttpHeaders.ContentType)?.size ?: 0
            capturedXtbzValues = request.headers.getAll("xtbz").orEmpty()
            MockReply(
                status = 200,
                body = """{"code":0,"msg":"签到成功"}""",
                headers = listOf(
                    "Set-Cookie" to "sessionid=; Max-Age=0; Path=/",
                    "Set-Cookie" to "csrftoken=deleted; Expires=Thu, 01 Jan 1970 00:00:00 GMT",
                    "set-auth" to "Bearer winner-token",
                    "authorization" to "Bearer loser-token",
                ),
            )
        }
        val apiClient = api(engine)
        val res = apiClient.call(
            account = account.copy(sessionId = "keep-sid", csrfToken = "keep-csrf"),
            endpointName = "checkinDesktop",
            vars = Template.varsOf("lessonId" to "42"),
            extraHeaders = mapOf("xtbz" to "override-xtbz"),
        )
        assertEquals(0, capturedContentTypeCount, "TextContent 自身携带 Content-Type，不应在 request.headers 重复追加")
        assertEquals(listOf("override-xtbz"), capturedXtbzValues, "extraHeaders 应去重覆盖而非重复追加")
        assertEquals("winner-token", res.auth?.bearer, "set-auth 优先级必须高于 authorization")
        assertNull(res.auth?.sessionId, "Max-Age=0 的空 Set-Cookie 应忽略")
        assertNull(res.auth?.csrfToken, "1970 过期 deleted Set-Cookie 应忽略")

        // 结合引擎确认原 sessionId/csrfToken 未被清空
        val signEngine = SignInEngine(apiClient, profile, onAccountUpdated = { updates += it })
        signEngine.signIn(account.copy(sessionId = "keep-sid", csrfToken = "keep-csrf"), QrParser.parse("lessonId=42", profile))
        assertEquals("keep-sid", updates.firstOrNull()?.sessionId)
        assertEquals("keep-csrf", updates.firstOrNull()?.csrfToken)
        assertTrue(updates.firstOrNull()?.lastOkAt != null, "成功响应刷新 lastOkAt")
    }

    @Test
    fun `HTTP 200 业务鉴权失败判 AUTH_REQUIRED 且网络异常绝不误判为 AUTH_REQUIRED`() = runTest {
        val auth200Engine = simpleMock { 200 to """{"code":40100,"msg":"Invalid TOKEN, please re-login"}""" }
        val rAuth = SignInEngine(api(auth200Engine), profile)
            .signIn(account, QrParser.parse("lessonId=1", profile))
        assertEquals(SignState.AUTH_REQUIRED, rAuth.state)

        val netErrEngine = MockEngine { throw RuntimeException("Connection reset while checking token") }
        val rNet = SignInEngine(api(netErrEngine), profile).signIn(
            account,
            QrParser.parse("lessonId=1", profile),
            SignOptions(maxAttemptsPerStrategy = 2, baseBackoffMs = 0),
        )
        assertEquals(SignState.ERROR, rNet.state, "网络异常必须判 ERROR，不能因异常文本含 token 误判 AUTH_REQUIRED")
    }

    @Test
    fun `非 JSON 响应命中已签到判 ALREADY 但 401 优先级高于 alreadyKeywords`() = runTest {
        val plainAlready = mock {
            MockReply(status = 200, body = "您已签到，无需重复提交", contentType = "text/plain")
        }
        val rAlready = SignInEngine(api(plainAlready), profile)
            .signIn(account, QrParser.parse("lessonId=1", profile))
        assertEquals(SignState.ALREADY, rAlready.state)

        val auth401WithAlready = mock {
            MockReply(status = 401, body = "未登录：已签到状态不可查", contentType = "text/plain")
        }
        val r401 = SignInEngine(api(auth401WithAlready), profile)
            .signIn(account, QrParser.parse("lessonId=1", profile))
        assertEquals(SignState.AUTH_REQUIRED, r401.state)
    }

    @Test
    fun `5xx 重试耗尽产出 ERROR 且保留完整重试轨迹，5xx 含过期关键词立即中止重试`() = runTest {
        var calls503 = 0
        val engine503 = simpleMock {
            calls503++
            503 to """{"code":50300,"msg":"服务繁忙"}"""
        }
        val rError = SignInEngine(api(engine503), profile).signIn(
            account,
            QrParser.parse("lessonId=1", profile),
            SignOptions(strategyIds = listOf("LESSON_DESKTOP"), maxAttemptsPerStrategy = 3, baseBackoffMs = 1),
        )
        assertEquals(SignState.ERROR, rError.state)
        assertEquals(3, calls503)
        assertEquals(3, rError.attempts.size)

        var callsExpired500 = 0
        val engineExpired500 = simpleMock {
            callsExpired500++
            500 to """{"code":50001,"msg":"二维码已失效"}"""
        }
        val rExpired = SignInEngine(api(engineExpired500), profile).signIn(
            account,
            QrParser.parse("c=a&t=1&s=sig&lessonId=1", profile),
            SignOptions(maxAttemptsPerStrategy = 3, baseBackoffMs = 1),
        )
        assertEquals(SignState.TICKET_EXPIRED, rExpired.state)
        assertEquals(1, callsExpired500, "即使 HTTP 500，命中 expiredKeywords 也必须立即中止重试与策略链")
    }

    @Test
    fun `演练模式即使缺 lessonId 也绝对零网络请求并返回 DRY_RUN`() = runTest {
        var calls = 0
        val engine = simpleMock {
            calls++
            200 to """{"code":0}"""
        }
        val signEngine = SignInEngine(api(engine), profile)
        // 无 lessonId 的动态码：真实模式会调用 discover()，演练模式必须跳过！
        val report = signEngine.signInAll(
            listOf(account),
            QrParser.parse("c=abc&t=1763900000&s=sig&v=2", profile),
            SignOptions(dryRun = true),
        )
        assertEquals(0, calls, "dryRun 必须跳过 discover() 且发起零网络请求")
        assertEquals(1, report.dryRunCount)
        assertEquals(0, report.failedCount)
        assertEquals(SignState.DRY_RUN, report.results.single().state)
        assertTrue(report.results.single().attempts.isNotEmpty())
        assertTrue(report.results.single().attempts.all { it.requestLine.contains("POST") })
    }

    @Test
    fun `discover 不吞掉 401 与网络异常并支持回填 auth`() = runTest {
        val authFailEngine = simpleMock { 401 to """{"code":40100,"msg":"会话已过期"}""" }
        val rAuth = SignInEngine(api(authFailEngine), profile)
            .signIn(account, QrParser.parse("c=a&t=1&s=sig", profile))
        assertEquals(SignState.AUTH_REQUIRED, rAuth.state)

        val netFailEngine = MockEngine { throw RuntimeException("DNS timeout") }
        val rErr = SignInEngine(api(netFailEngine), profile)
            .signIn(account, QrParser.parse("c=a&t=1&s=sig", profile))
        assertEquals(SignState.ERROR, rErr.state)

        // discover 带新 auth 回填并传递给后续签到策略
        val seenTokens = mutableListOf<String?>()
        val refreshEngine = mock { request ->
            seenTokens += request.headers[HttpHeaders.Authorization]
            when (request.url.encodedPath) {
                "/api/v3/classroom/on-lesson-upcoming-exam" -> MockReply(
                    status = 200,
                    body = """{"code":0,"data":{"onLessonClassrooms":[{"lessonId":"777","classroomId":"88","courseName":"高数"}]}}""",
                    headers = listOf("set-auth" to "Bearer from-discover"),
                )
                "/api/v3/lesson/checkin" -> MockReply(status = 200, body = """{"code":0,"msg":"签到成功"}""")
                else -> MockReply(status = 404, body = """{"code":40400}""")
            }
        }
        val rOk = SignInEngine(api(refreshEngine), profile)
            .signIn(account, QrParser.parse("c=a&t=1&s=sig", profile))
        assertEquals(SignState.SUCCESS, rOk.state)
        assertEquals("777", rOk.lessonId)
        assertEquals(listOf<String?>("Bearer token-1", "Bearer from-discover"), seenTokens)
    }

    @Test
    fun `多账号并发保持顺序且重抛 CancellationException`() = runTest {
        val engine = simpleMock { 200 to """{"code":0,"msg":"签到成功"}""" }
        val signEngine = SignInEngine(api(engine), profile)
        val accounts = (1..6).map {
            account.copy(id = "a$it", label = "账号$it", bearer = "token-$it")
        }
        val report = signEngine.signInAll(
            accounts,
            QrParser.parse("lessonId=42", profile),
            SignOptions(concurrency = 3, staggerMs = 1),
        )
        assertEquals(6, report.successCount)
        assertEquals(0, report.failedCount)
        assertEquals(accounts.map { it.id }, report.results.map { it.accountId })

        val cancellingEngine = MockEngine { throw CancellationException("cancelled") }
        assertFailsWith<CancellationException> {
            SignInEngine(api(cancellingEngine), profile).signInAll(
                listOf(account),
                QrParser.parse("lessonId=42", profile),
            )
        }
    }

    @Test
    fun `SignOptions 默认值对齐文档并校验边界`() {
        val defaults = SignOptions()
        assertEquals(3, defaults.maxAttemptsPerStrategy)
        assertEquals(800L, defaults.baseBackoffMs)
        assertFailsWith<IllegalArgumentException> { SignOptions(concurrency = 0) }
        assertFailsWith<IllegalArgumentException> { SignOptions(concurrency = 33) }
        assertFailsWith<IllegalArgumentException> { SignOptions(maxAttemptsPerStrategy = 0) }
        assertFailsWith<IllegalArgumentException> { SignOptions(baseBackoffMs = -1) }
    }
}
