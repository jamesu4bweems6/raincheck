package cn.raincheck.core

import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.request.HttpRequestData
import io.ktor.http.HeadersBuilder
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.utils.io.ByteReadChannel
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class LoginServiceTest {

    private val profile: ProtocolProfile = ProtocolProfile.parse(readProtocolFile("profile.json"))
    private val edition: Edition = profile.defaultEditionSpec()

    private data class MockReply(
        val status: Int,
        val body: String,
        val headers: List<Pair<String, String>> = emptyList(),
    )

    private fun service(responder: (HttpRequestData) -> MockReply): LoginService {
        val engine = MockEngine { request ->
            val reply = responder(request)
            val headers = HeadersBuilder().apply {
                append(HttpHeaders.ContentType, "application/json")
                reply.headers.forEach { (k, v) -> append(k, v) }
            }.build()
            respond(
                content = ByteReadChannel(reply.body),
                status = HttpStatusCode.fromValue(reply.status),
                headers = headers,
            )
        }
        return LoginService(RainCheckApi(profile, HttpClient(engine) { expectSuccess = false }), profile)
    }

    private fun bodyOf(request: HttpRequestData): String =
        runCatching { (request.body as io.ktor.http.content.TextContent).text }.getOrElse { "" }

    @Test
    fun `扫码登录全流程 pre-info 到 SCANNED 到 NEED_CODE 重试再到 AUTHORIZED 与 verify 回填`() = runTest {
        var pollRound = 0
        var waitCookieSeen: String? = null
        var waitCsrfSeen: String? = null

        val svc = service { request ->
            when (request.url.encodedPath) {
                "/api/v3/user/login/pre-info" -> MockReply(
                    status = 200,
                    body = """{"code":0,"data":{"qrContent":"https://open.weixin.qq.com/connect/qrconnect?state=lt-1","token":"lt-1"}}""",
                    headers = listOf("Set-Cookie" to "csrftoken=pre-csrf-1; Path=/"),
                )
                "/api/v3/user/login/wait-for-scan" -> {
                    pollRound++
                    waitCookieSeen = request.headers[HttpHeaders.Cookie]
                    waitCsrfSeen = request.headers["X-CSRFToken"]
                    when (pollRound) {
                        1 -> MockReply(200, """{"code":40001,"msg":"等待扫码","data":{"token":null}}""")
                        2 -> MockReply(200, """{"code":0,"msg":"已扫码，等待确认","data":{"scanned":true}}""")
                        else -> MockReply(200, """{"code":40010,"msg":"需要验证码","data":{"verify_token":"vt-99"}}""")
                    }
                }
                "/api/v3/user/login" -> MockReply(200, """{"code":40002,"msg":"等待扫码"}""")
                "/api/v3/user/login/login-with-code" -> {
                    val body = bodyOf(request)
                    if (body.contains("\"code\":\"0000\"")) {
                        MockReply(200, """{"code":40004,"msg":"验证码错误","data":{"verify_token":"vt-99"}}""")
                    } else {
                        MockReply(
                            status = 200,
                            body = """{"code":0,"msg":"登录成功","data":{"verified":true}}""",
                            headers = listOf(
                                "set-auth" to "Bearer login-tok-1",
                                "Set-Cookie" to "sessionid=login-sid-1; Path=/; HttpOnly",
                            ),
                        )
                    }
                }
                "/api/v3/user/basic-info" -> MockReply(
                    status = 200,
                    body = """{"code":0,"data":{"id":"u888","name":"李同学"}}""",
                    headers = listOf("set-auth" to "Bearer refreshed-me-tok"),
                )
                else -> MockReply(404, """{"code":40400}""")
            }
        }

        // 1. start -> PENDING
        val started = svc.start(edition)
        assertEquals(LoginState.PENDING, started.state)
        assertEquals("lt-1", started.loginToken)
        assertNotNull(started.qrContent)

        // 2. 第 1 次 poll：data.token == JsonNull，绝不误判为 NEED_CODE
        val p1 = svc.poll(edition, "lt-1")
        assertEquals(LoginState.PENDING, p1.state)
        assertTrue(waitCookieSeen?.contains("csrftoken=pre-csrf-1") == true, "pre-info 下发的 Cookie 应传递给 wait-for-scan")
        assertEquals("pre-csrf-1", waitCsrfSeen)

        // 3. 第 2 次 poll -> SCANNED
        val p2 = svc.poll(edition, "lt-1")
        assertEquals(LoginState.SCANNED, p2.state)

        // 4. 第 3 次 poll -> NEED_CODE 并拿到 verify_token
        val p3 = svc.poll(edition, "lt-1")
        assertEquals(LoginState.NEED_CODE, p3.state)
        assertEquals("vt-99", p3.loginToken)

        // 5. 格式不合法的验证码 -> NEED_CODE 保留 verifyToken
        val badFmt = svc.submitCode(edition, "vt-99", "12a")
        assertEquals(LoginState.NEED_CODE, badFmt.state)
        assertEquals("vt-99", badFmt.loginToken)

        // 6. 错误的 4 位验证码 -> NEED_CODE 保留 verifyToken 便于重试
        val wrong = svc.submitCode(edition, "vt-99", "0000")
        assertEquals(LoginState.NEED_CODE, wrong.state)
        assertEquals("vt-99", wrong.loginToken)

        // 7. 正确的 4 位验证码 -> AUTHORIZED，吸收 basic-info 回填并保留 pre-info 的 csrftoken 与 createdAt
        val ok = svc.submitCode(edition, "vt-99", "1234")
        assertEquals(LoginState.AUTHORIZED, ok.state)
        val acc = ok.account
        assertNotNull(acc)
        assertEquals("refreshed-me-tok", acc.bearer, "verify 响应的 set-auth 必须被吸收")
        assertEquals("login-sid-1", acc.sessionId)
        assertEquals("pre-csrf-1", acc.csrfToken, "pre-info 的 csrftoken 应延续到最终账号")
        assertEquals("李同学", acc.label)
        assertEquals("u888", acc.userId)
        assertTrue(acc.createdAt > 0L, "新账号必须写入 createdAt")
        assertNotNull(acc.lastOkAt)
    }

    @Test
    fun `start 遇 404 或 500 报 ERROR 而非 EXPIRED`() = runTest {
        val svc404 = service { MockReply(404, """{"code":40400,"msg":"not found"}""") }
        assertEquals(LoginState.ERROR, svc404.start(edition).state)

        val svc500 = service { MockReply(500, """{"code":500,"msg":"internal error"}""") }
        assertEquals(LoginState.ERROR, svc500.start(edition).state)
    }

    @Test
    fun `isExpired 优先级高于 needsCode 且 finishLogin 无凭据绝不伪造 AUTHORIZED`() = runTest {
        // 同时带 verify_token 和失效消息时，必须判 EXPIRED
        val expiredSvc = service { request ->
            when (request.url.encodedPath) {
                "/api/v3/user/login/wait-for-scan" ->
                    MockReply(200, """{"code":50000,"msg":"二维码已失效","data":{"verify_token":"stale-vt"}}""")
                else -> MockReply(200, """{"code":40002}""")
            }
        }
        assertEquals(LoginState.EXPIRED, expiredSvc.poll(edition, "lt-exp").state)

        // loginPoll 返回 code=0 但没有任何 set-auth / Set-Cookie 时，绝不返回 AUTHORIZED(account=null)
        val noCredSvc = service { request ->
            when (request.url.encodedPath) {
                "/api/v3/user/login/wait-for-scan" -> MockReply(200, """{"code":0,"data":{"confirmed":true}}""")
                "/api/v3/user/login" -> MockReply(200, """{"code":0,"msg":"ok","data":{"id":"u1"}}""")
                else -> MockReply(404, """{}""")
            }
        }
        val noCredRes = noCredSvc.poll(edition, "lt-nocred")
        assertEquals(LoginState.ERROR, noCredRes.state)
        assertNull(noCredRes.account)
    }

    @Test
    fun `start 遵守 endpoints loginPre 配置且 JsonNull 缺少 token 报 ERROR`() = runTest {
        var requestedPath = ""
        val customProfile = profile.copy(
            endpoints = profile.endpoints + ("loginPre" to EndpointSpec(method = "GET", path = "/api/v3/custom/pre", auth = false)),
        )
        val engine = MockEngine { request ->
            requestedPath = request.url.encodedPath
            respond(
                content = ByteReadChannel("""{"code":0,"data":{"qrContent":"https://x","token":null}}"""),
                status = HttpStatusCode.OK,
                headers = HeadersBuilder().apply { append(HttpHeaders.ContentType, "application/json") }.build(),
            )
        }
        val svc = LoginService(RainCheckApi(customProfile, HttpClient(engine) { expectSuccess = false }), customProfile)
        val res = svc.start(edition)
        assertEquals("/api/v3/custom/pre", requestedPath, "start 必须遵守 profile.endpoints.loginPre")
        assertEquals(LoginState.ERROR, res.state, "token 为 JsonNull 时不能当作字符串 \"null\"")
    }
}
