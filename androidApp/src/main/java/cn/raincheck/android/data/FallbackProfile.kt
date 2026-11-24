package cn.raincheck.android.data

import cn.raincheck.core.AuthSpec
import cn.raincheck.core.Edition
import cn.raincheck.core.EndpointSpec
import cn.raincheck.core.ProtocolProfile
import cn.raincheck.core.QrSpec
import cn.raincheck.core.ResultSpec
import cn.raincheck.core.StrategySpec
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * `assets/protocol_profile.json` 读取或解析异常时的内置完整兜底配置。
 *
 * 与仓库 `protocol/profile.json` 保持 100% 字段与端点一致（含 7 站点、17 端点、6 策略、
 * `qr` 白名单及 `result` 双字段兼容规则），保证即使资源损坏也绝不退化安全边界。
 */
internal object FallbackProfile {

    private const val USER_AGENT =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
            "(KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36"

    private fun body(vararg pairs: Pair<String, Any>): JsonObject = buildJsonObject {
        pairs.forEach { (key, value) ->
            when (value) {
                is Int -> put(key, value)
                is Long -> put(key, value)
                is Boolean -> put(key, value)
                else -> put(key, value.toString())
            }
        }
    }

    fun build(): ProtocolProfile = ProtocolProfile(
        version = 1,
        name = "yuketang-fallback",
        updatedAt = "2026-11-24",
        defaultEdition = "www",
        editions = listOf(
            Edition.WWW,
            Edition.PRO,
            Edition.TSINGHUA,
            Edition.CHANGJIANG,
            Edition.HUANGHE,
            Edition.XUETANGX,
            Edition.MOCK,
        ),
        headers = linkedMapOf(
            "xtbz" to "ykt",
            "desktop-v" to "v2",
            "X-Client" to "desktop",
            "Origin" to "file://",
            "Accept" to "application/json, text/plain, */*",
        ),
        userAgent = USER_AGENT,
        auth = AuthSpec(
            bearerHeader = "Authorization",
            bearerPrefix = "Bearer ",
            cookieNames = listOf("sessionid", "csrftoken"),
            csrfCookie = "csrftoken",
            csrfHeader = "X-CSRFToken",
            tokenResponseHeaders = listOf("set-auth", "authorization"),
        ),
        endpoints = linkedMapOf(
            "me" to EndpointSpec(
                method = "GET",
                path = "/api/v3/user/basic-info",
                auth = true,
            ),
            "loginPre" to EndpointSpec(
                method = "GET",
                path = "/api/v3/user/login/pre-info",
                auth = false,
                note = "外部桌面端脚本推断，未经实网抓包验证",
            ),
            "loginWait" to EndpointSpec(
                method = "POST",
                path = "/api/v3/user/login/wait-for-scan",
                body = body("token" to "{loginToken}"),
                auth = false,
                note = "外部桌面端脚本推断，未经实网抓包验证",
            ),
            "loginPoll" to EndpointSpec(
                method = "POST",
                path = "/api/v3/user/login",
                body = body("token" to "{loginToken}"),
                auth = false,
                note = "外部桌面端脚本推断，未经实网抓包验证",
            ),
            "loginCode" to EndpointSpec(
                method = "POST",
                path = "/api/v3/user/login/login-with-code",
                body = body("token" to "{loginToken}", "code" to "{code}"),
                auth = false,
                note = "外部桌面端脚本推断，未经实网抓包验证",
            ),
            "activeLesson" to EndpointSpec(
                method = "GET",
                path = "/api/v3/classroom/on-lesson-upcoming-exam",
                auth = true,
            ),
            "checkinList" to EndpointSpec(
                method = "POST",
                path = "/api/v3/lesson/checkin-list",
                body = body("lesson_id" to "{lessonId}", "page" to 0, "limit" to 20),
                auth = true,
                note = "IPA 实证属教师端 remote_control POST 接口（postSignList），非学生端 GET",
            ),
            "checkinDetail" to EndpointSpec(
                method = "POST",
                path = "/api/v3/lesson/checkin/detail",
                body = body("lesson_id" to "{lessonId}", "checkin_id" to "{checkinId}"),
                auth = true,
                note = "IPA 实证属教师端 remote_control POST 接口（postSignDetail），非学生端 GET",
            ),
            "lessonBasic" to EndpointSpec(
                method = "GET",
                path = "/api/v3/lesson/basic-info",
                query = linkedMapOf("lesson_id" to "{lessonId}"),
                auth = true,
                note = "IPA 实证查询参数名为 lesson_id",
            ),
            "checkinTicket" to EndpointSpec(
                method = "POST",
                path = "/api/v3/lesson/checkin",
                body = body(
                    "lessonId" to "{lessonId}",
                    "source" to "{source}",
                    "ticket" to "{c}",
                    "t" to "{t}",
                    "s" to "{s}",
                ),
                auth = true,
                note = "路径获 IPA 实证；source/ticket/t/s 请求体由外部桌面端脚本推断",
            ),
            "checkinDesktop" to EndpointSpec(
                method = "POST",
                path = "/api/v3/lesson/checkin",
                body = body("lessonId" to "{lessonId}", "source" to 1),
                auth = true,
            ),
            "checkinWeb" to EndpointSpec(
                method = "POST",
                path = "/api/lesson/web_check_in",
                body = body("lessonId" to "{lessonId}", "source" to 1),
                auth = true,
            ),
            "locationEligibility" to EndpointSpec(
                method = "GET",
                path = "/api/v3/lesson/location-checkin/eligibility",
                query = linkedMapOf("lessonId" to "{lessonId}"),
                auth = true,
                note = "学生端定位签到资格查询（需登录态，尚未接入自动签到引擎）",
            ),
            "locationPreview" to EndpointSpec(
                method = "GET",
                path = "/api/v3/lesson/location-checkin/preview",
                query = linkedMapOf("lessonId" to "{lessonId}"),
                auth = true,
                note = "学生端定位签到预览（尚未接入自动签到引擎）",
            ),
            "locationSession" to EndpointSpec(
                method = "POST",
                path = "/api/v3/lesson/location-checkin/session",
                body = body("lessonId" to "{lessonId}"),
                auth = true,
                note = "IPA 实证属教师端创建定位签到会话接口（非学生端流程）",
            ),
            "locationUpdateSession" to EndpointSpec(
                method = "POST",
                path = "/api/v3/location-checkin/update-session",
                body = body("lessonId" to "{lessonId}"),
                auth = true,
                note = "IPA 实证教师端更新定位签到会话接口（路径不含 /lesson/，非学生端流程）",
            ),
            "locationSubmit" to EndpointSpec(
                method = "POST",
                path = "/api/v3/lesson/location-checkin/submit",
                body = body(
                    "lessonId" to "{lessonId}",
                    "latitude" to "{latitude}",
                    "longitude" to "{longitude}",
                    "accuracy" to "{accuracy}",
                ),
                auth = true,
                note = "学生端定位签到提交（尚未接入自动签到引擎）",
            ),
        ),
        strategies = listOf(
            StrategySpec(
                id = "DYN_TICKET_14",
                endpoint = "checkinTicket",
                appliesTo = listOf("DYNAMIC_CHECKIN"),
                requires = listOf("lessonId", "c"),
                vars = body("source" to 14),
                note = "PC/桌面端来源，公开实现里成功率最高（待实网验证）",
            ),
            StrategySpec(
                id = "DYN_TICKET_5",
                endpoint = "checkinTicket",
                appliesTo = listOf("DYNAMIC_CHECKIN"),
                requires = listOf("lessonId", "c"),
                vars = body("source" to 5),
                note = "小程序来源，部分校区只认这个（待实网验证）",
            ),
            StrategySpec(
                id = "LESSON_DESKTOP",
                endpoint = "checkinDesktop",
                appliesTo = listOf("DYNAMIC_CHECKIN", "LESSON_ONLY", "UNKNOWN"),
                requires = listOf("lessonId"),
                note = "静态码/课堂级签到，只要 lessonId",
            ),
            StrategySpec(
                id = "LESSON_WEB",
                endpoint = "checkinWeb",
                appliesTo = listOf("LESSON_ONLY", "UNKNOWN"),
                requires = listOf("lessonId"),
                note = "网页端兜底",
            ),
            StrategySpec(
                id = "QR_URL_POST",
                endpoint = null,
                appliesTo = listOf("DYNAMIC_CHECKIN"),
                requires = listOf("c"),
                note = "仅允许同源或白名单域名直接把二维码 URL POST 一次",
            ),
            StrategySpec(
                id = "QR_URL_GET",
                endpoint = null,
                appliesTo = listOf("DYNAMIC_CHECKIN"),
                requires = listOf("c"),
                note = "仅允许同源或白名单域名把二维码 URL 原样 GET",
            ),
        ),
        qr = QrSpec(
            dynamicKeys = listOf("c", "t", "s"),
            lessonKeys = listOf("lessonId", "lesson_id", "lessonid", "lid"),
            classroomKeys = listOf("classroomId", "classroom_id", "classroomid", "cid"),
            checkinKeys = listOf("checkinId", "checkin_id", "signId", "sign_id"),
            loginPathHints = listOf("login", "qrcode", "scan", "qrconnect"),
            schemes = listOf("https", "http", "app", "yuketang", "ykt", "rainclassroom"),
            allowedUrlHosts = listOf(
                "www.yuketang.cn",
                "pro.yuketang.cn",
                "changjiang.yuketang.cn",
                "huanghe.yuketang.cn",
                "www.xuetangx.com",
                "127.0.0.1:8787",
            ),
        ),
        result = ResultSpec(
            codeField = "code",
            altCodeKeys = listOf("errcode"),
            okCodes = listOf(0),
            messageFields = listOf("msg", "message"),
            altMessageKeys = listOf("errmsg"),
            alreadyKeywords = listOf("已签到", "已经签到", "重复签到", "已参与"),
            authKeywords = listOf("登录", "未授权", "身份", "token", "会话", "unauthorized"),
            expiredKeywords = listOf("失效", "过期", "不存在", "二维码已"),
            retryHttpStatus = listOf(408, 425, 429, 500, 502, 503, 504),
        ),
    )
}
