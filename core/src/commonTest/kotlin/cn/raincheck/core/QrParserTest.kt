package cn.raincheck.core

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class QrParserTest {

    private val realProfile: ProtocolProfile = ProtocolProfile.parse(readProtocolFile("profile.json"))
    private val json = Json { ignoreUnknownKeys = true }

    @Serializable
    private data class VectorFile(
        val version: Int = 1,
        val cases: List<VectorCase> = emptyList(),
    )

    @Serializable
    private data class VectorCase(
        val name: String,
        val raw: String,
        val expect: VectorExpect,
    )

    @Serializable
    private data class VectorExpect(
        val kind: String,
        val host: String? = null,
        val lessonId: String? = null,
        val classroomId: String? = null,
        val checkinId: String? = null,
        val params: Map<String, String>? = null,
    )

    @Test
    fun `逐条断言真实 protocol vectors qr_cases 全部测试向量`() {
        val vectorFile = json.decodeFromString(
            VectorFile.serializer(),
            readProtocolFile("vectors/qr_cases.json"),
        )
        assertTrue(vectorFile.cases.size >= 15, "预期扩充后的向量数 >= 15，实际 ${vectorFile.cases.size}")

        vectorFile.cases.forEach { tc ->
            val ticket = QrParser.parse(tc.raw, realProfile)
            assertEquals(
                TicketKind.valueOf(tc.expect.kind),
                ticket.kind,
                "用例 [${tc.name}] kind 不匹配: raw=${tc.raw}",
            )
            if (tc.expect.host != null) {
                assertEquals(tc.expect.host, ticket.host, "用例 [${tc.name}] host 不匹配")
            }
            if (tc.expect.lessonId != null) {
                assertEquals(tc.expect.lessonId, ticket.lessonId, "用例 [${tc.name}] lessonId 不匹配")
            }
            if (tc.expect.classroomId != null) {
                assertEquals(tc.expect.classroomId, ticket.classroomId, "用例 [${tc.name}] classroomId 不匹配")
            }
            if (tc.expect.checkinId != null) {
                assertEquals(tc.expect.checkinId, ticket.checkinId, "用例 [${tc.name}] checkinId 不匹配")
            }
            if (tc.expect.params != null) {
                assertEquals(tc.expect.params, ticket.params, "用例 [${tc.name}] params 不匹配")
            }
        }
    }

    @Test
    fun `动态码判定真正读取 profile qr dynamicKeys`() {
        val customProfile = realProfile.copy(
            qr = realProfile.qr.copy(dynamicKeys = listOf("code", "ts")),
        )
        val matched = QrParser.parse("https://www.yuketang.cn/x?code=abc&ts=1763900000", customProfile)
        assertEquals(TicketKind.DYNAMIC_CHECKIN, matched.kind)

        val notMatched = QrParser.parse("c=abc&t=1763900000&s=sig", customProfile)
        assertEquals(TicketKind.UNKNOWN, notMatched.kind)
    }

    @Test
    fun `loginPathHints 仅匹配 path 绝不误匹配 host`() {
        val hostOnlyLogin = QrParser.parse("https://login.evil.example/v2/web/index", realProfile)
        assertEquals(TicketKind.UNKNOWN, hostOnlyLogin.kind)

        val customProfile = realProfile.copy(
            qr = realProfile.qr.copy(loginPathHints = listOf("custom-auth")),
        )
        val pathMatched = QrParser.parse("https://www.yuketang.cn/custom-auth/step1", customProfile)
        assertEquals(TicketKind.LOGIN, pathMatched.kind)
    }

    @Test
    fun `profile 荷塘域名与学堂在线配置准确且 updatedAt 已反序列化`() {
        assertEquals("2026-11-24", realProfile.updatedAt)
        assertEquals("pro.yuketang.cn", realProfile.edition("tsinghua")?.host)
        assertEquals("pro.yuketang.cn", realProfile.edition("pro")?.host)
        assertEquals("www.xuetangx.com", realProfile.edition("xuetangx")?.host)
        assertEquals(true, realProfile.endpoint("locationEligibility").auth)
        assertEquals("POST", realProfile.endpoint("checkinList").method)
        assertEquals("POST", realProfile.endpoint("checkinDetail").method)
        assertEquals("/api/v3/location-checkin/update-session", realProfile.endpoint("locationUpdateSession").path)
        assertTrue(realProfile.qr.schemes.contains("app"))
        assertTrue(realProfile.result.altCodeKeys.contains("errcode"))
        assertTrue(realProfile.result.altMessageKeys.contains("errmsg"))
        assertFalse(realProfile.result.alreadyKeywords.contains("签到成功"))
    }

    @Test
    fun `QrUrl 白名单严格阻断第三方域名与协议降级与 userinfo 欺骗`() {
        val prodAccount = Account(id = "a1", label = "学生", host = "www.yuketang.cn", scheme = "https", bearer = "tok")
        val mockAccount = Account(id = "a2", label = "演练", host = "127.0.0.1:18787", scheme = "http", bearer = "tok")

        assertTrue(realProfile.isAllowedQrUrl("https://www.yuketang.cn/api/v3/lesson/checkin?c=1", prodAccount))
        assertTrue(realProfile.isAllowedQrUrl("https://PRO.YUKETANG.CN:443/api/v3/lesson/checkin?c=1", prodAccount))
        assertTrue(realProfile.isAllowedQrUrl("http://127.0.0.1:8787/api/v3/lesson/checkin?c=1", prodAccount))
        assertTrue(realProfile.isAllowedQrUrl("http://127.0.0.1:18787/api/v3/lesson/checkin?c=1", mockAccount))

        assertFalse(realProfile.isAllowedQrUrl("https://evil.example/x?c=1", prodAccount))
        assertFalse(realProfile.isAllowedQrUrl("https://www.yuketang.cn.evil.com/x?c=1", prodAccount))
        assertFalse(realProfile.isAllowedQrUrl("https://www.yuketang.cn@evil.example/x?c=1", prodAccount))
        assertFalse(realProfile.isAllowedQrUrl("https://www.yuketang.cn\\@evil.example/x?c=1", prodAccount))
        assertFalse(realProfile.isAllowedQrUrl("http://www.yuketang.cn/api/v3/lesson/checkin?c=1", prodAccount))
        assertFalse(realProfile.isAllowedQrUrl("https://www.yuketang.cn:9999/x?c=1", prodAccount))
        assertFalse(realProfile.isAllowedQrUrl("app://yuketang/checkin?c=1", prodAccount))
    }

    @Test
    fun `Template 递归渲染 JsonArray 保留浮点数值并对路径段编码且杜绝 JsonNull`() {
        val vars = Template.varsOf(
            "lessonId" to "123/../../admin?x=1",
            "lat" to 39.99125,
            "acc" to 12.5f,
            "tag" to "ok",
        )
        val bodyTemplate = JsonObject(
            mapOf(
                "coords" to JsonArray(listOf(JsonPrimitive("{lat}"), JsonPrimitive("{acc}"))),
                "nested" to JsonArray(listOf(JsonObject(mapOf("label" to JsonPrimitive("prefix-{tag}"))))),
            ),
        )
        val rendered = Template.renderBody(bodyTemplate, vars)
        val coords = rendered["coords"] as JsonArray
        assertEquals(39.99125, (coords[0] as JsonPrimitive).doubleOrNull)
        assertEquals(12.5, (coords[1] as JsonPrimitive).doubleOrNull)

        val nested = rendered["nested"] as JsonArray
        assertEquals("prefix-ok", ((nested[0] as JsonObject)["label"]).asNonNullStringOrNull())

        val safePath = Template.renderPath("/api/v3/lesson/{lessonId}/info", vars)
        assertFalse(safePath.contains("../"))
        assertFalse(safePath.contains("?x=1"))
        assertTrue(safePath.contains("%2F"))

        // JsonNull 安全提取
        assertNull(JsonNull.asNonNullStringOrNull())
        assertNull(JsonNull.asNonNullIntOrNull())
        assertNull(JsonNull.asNonNullBoolOrNull())
        assertEquals("abc", JsonPrimitive("abc").asNonNullStringOrNull())
        assertEquals(42, JsonPrimitive(42).asNonNullIntOrNull())
        assertEquals(true, JsonPrimitive(true).asNonNullBoolOrNull())
    }

    @Test
    fun `Account maskedCredential 强化短 token 遮蔽与 Edition presets 完整`() {
        val shortAcc = Account(id = "1", label = "短", bearer = "123456789012")
        assertEquals("****", shortAcc.maskedCredential())

        val medAcc = Account(id = "2", label = "中", bearer = "1234567890123456")
        assertEquals("12…56", medAcc.maskedCredential())

        val longAcc = Account(id = "3", label = "长", bearer = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9")
        assertEquals("eyJh…VCJ9".replace("VCJ9", "CJ9"), longAcc.maskedCredential())

        assertNotNull(Edition.presets.firstOrNull { it.id == "tsinghua" && it.host == "pro.yuketang.cn" })
        assertNotNull(Edition.presets.firstOrNull { it.id == "xuetangx" && it.host == "www.xuetangx.com" })
    }
}
