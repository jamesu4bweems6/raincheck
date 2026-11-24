//
//  Models.swift
//  RainCheck
//
//  与 `core/src/commonMain/kotlin/cn/raincheck/core/` 100% 对齐的数据模型。
//  全模型严格遵守 `Sendable`，消除 `[String: Any]` 跨并发边界隐患；
//  `SignResult` 显式声明 `CodingKeys` 永久排除 `refreshedAccount`，确保导出 JSON 零凭据泄露。
//

import Foundation

// MARK: - 通用字符串与时间工具

extension String {
    /// 去掉首尾空白字符。
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 去空白后为空则返回 nil。
    var trimmedNonEmpty: String? {
        let value = trimmed
        return value.isEmpty ? nil : value
    }
}

/// 平台时间（毫秒），与 Kotlin 的 `nowMillis()` 对齐。
enum TimeUtil {
    static func nowMillis() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000.0).rounded())
    }

    static func format(millis: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(millis) / 1000.0)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    static func formatRelative(millis: Int64) -> String {
        let now = nowMillis()
        let diffSec = max(0, (now - millis) / 1000)
        if diffSec < 60 { return "刚刚" }
        if diffSec < 3600 { return "\(diffSec / 60) 分钟前" }
        if diffSec < 86400 { return "\(diffSec / 3600) 小时前" }
        return format(millis: millis)
    }
}

/// 账号 / 登录流程用的随机 id。
enum Ids {
    static func randomId() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    static func shortId(_ length: Int = 4) -> String {
        String(randomId().prefix(max(1, length)))
    }
}

// MARK: - 严格 Sendable 的类型化 JSON 值

/// 任意 JSON 值（Sendable），用于模板变量、请求体与响应体解析。
enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        // Swift Foundation JSONDecoder 对 Bool 严格匹配 JSON true/false（不接受 0/1），
        // 先判 Bool 可彻底杜绝 false 被误解为 Int 0。
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(Int.self) {
            self = .int(value)
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .double(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
            return
        }
        if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
            return
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "无法识别的 JSON 值")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    /// 非 null 原始标量字符串（容器类型与 null 返回 nil，杜绝把 Dict/Array 转调试串）。
    var nonNullScalarString: String? {
        switch self {
        case .string(let value):
            return value
        case .int(let value):
            return String(value)
        case .double(let value):
            if value == value.rounded() && abs(value) < 1e15 {
                return String(Int64(value))
            }
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .null, .array, .object:
            return nil
        }
    }

    /// 非 null 整数（显式排除 bool，防止 `false == 0` 误判成功）。
    var nonNullInt: Int? {
        switch self {
        case .int(let value):
            return value
        case .double(let value):
            if value == value.rounded(), value >= Double(Int.min), value <= Double(Int.max) {
                return Int(value)
            }
            return nil
        case .string(let text):
            return Int(text.trimmed)
        case .bool, .null, .array, .object:
            return nil
        }
    }

    /// 非 null 布尔值。
    var nonNullBool: Bool? {
        switch self {
        case .bool(let value):
            return value
        case .string(let text):
            switch text.trimmed.lowercased() {
            case "true": return true
            case "false": return false
            default: return nil
            }
        default:
            return nil
        }
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let map) = self { return map }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let items) = self { return items }
        return nil
    }

    /// 模板插值字符串（null -> ""）。
    var stringValue: String {
        switch self {
        case .null:
            return ""
        case .bool(let value):
            return value ? "true" : "false"
        case .int(let value):
            return String(value)
        case .double(let value):
            if value == value.rounded() && abs(value) < 1e15 {
                return String(Int64(value))
            }
            return String(value)
        case .string(let value):
            return value
        case .array, .object:
            return serialized()
        }
    }

    /// 序列化成紧凑 JSON 文本（键排序保证请求体可复现）。
    func serialized() -> String {
        switch self {
        case .null:
            return "null"
        case .bool(let value):
            return value ? "true" : "false"
        case .int(let value):
            return String(value)
        case .double(let value):
            if value == value.rounded() && abs(value) < 1e15 {
                return String(Int64(value))
            }
            return String(value)
        case .string(let value):
            return JSONValue.quoted(value)
        case .array(let items):
            return "[" + items.map { $0.serialized() }.joined(separator: ",") + "]"
        case .object(let map):
            let body = map.keys.sorted().map { key -> String in
                let value = map[key] ?? .null
                return JSONValue.quoted(key) + ":" + value.serialized()
            }
            return "{" + body.joined(separator: ",") + "}"
        }
    }

    static func quoted(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.append(Character(scalar))
                }
            }
        }
        out += "\""
        return out
    }
}

// MARK: - Codable 容错解码

extension KeyedDecodingContainer {
    func value<T: Decodable>(_ type: T.Type, _ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(type, forKey: key)) ?? fallback
    }

    func optional<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        try? decodeIfPresent(type, forKey: key)
    }
}

// MARK: - 站点（与 protocol/profile.json 7 项对齐）

struct Edition: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var label: String
    var host: String
    var scheme: String

    init(id: String, label: String, host: String, scheme: String = "https") {
        self.id = id
        self.label = label
        self.host = host
        self.scheme = scheme
    }

    enum CodingKeys: String, CodingKey {
        case id, label, host, scheme
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawId = container.value(String.self, .id, "")
        let rawHost = container.value(String.self, .host, "www.yuketang.cn")
        id = rawId.isEmpty ? rawHost : rawId
        label = container.value(String.self, .label, rawHost)
        host = rawHost
        scheme = container.value(String.self, .scheme, "https")
    }

    var baseUrl: String { "\(scheme)://\(host)" }

    static let WWW = Edition(id: "www", label: "雨课堂", host: "www.yuketang.cn")
    static let PRO = Edition(id: "pro", label: "雨课堂 Pro（荷塘/专业版）", host: "pro.yuketang.cn")
    static let TSINGHUA = Edition(id: "tsinghua", label: "荷塘雨课堂", host: "pro.yuketang.cn")
    static let CHANGJIANG = Edition(id: "changjiang", label: "长江雨课堂", host: "changjiang.yuketang.cn")
    static let HUANGHE = Edition(id: "huanghe", label: "黄河雨课堂", host: "huanghe.yuketang.cn")
    static let XUETANGX = Edition(id: "xuetangx", label: "学堂在线", host: "www.xuetangx.com")
    static let MOCK = Edition(id: "mock", label: "本地演练环境", host: "127.0.0.1:8787", scheme: "http")

    static let presets: [Edition] = [WWW, PRO, TSINGHUA, CHANGJIANG, HUANGHE, XUETANGX, MOCK]

    static func fromHost(_ host: String, scheme: String? = nil) -> Edition {
        if let match = presets.first(where: { $0.host.caseInsensitiveCompare(host) == .orderedSame }) {
            if let scheme, match.scheme.caseInsensitiveCompare(scheme) != .orderedSame {
                return Edition(id: match.id, label: match.label, host: match.host, scheme: scheme.lowercased())
            }
            return match
        }
        return Edition(id: host, label: host, host: host, scheme: scheme?.lowercased() ?? "https")
    }
}

// MARK: - 账号

struct Account: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var label: String
    var host: String
    var scheme: String
    var bearer: String?
    var sessionId: String?
    var csrfToken: String?
    var enabled: Bool
    var createdAt: Int64
    var lastOkAt: Int64?
    var userId: String?
    var note: String

    init(
        id: String = Ids.randomId(),
        label: String = "账号",
        host: String = "www.yuketang.cn",
        scheme: String = "https",
        bearer: String? = nil,
        sessionId: String? = nil,
        csrfToken: String? = nil,
        enabled: Bool = true,
        createdAt: Int64 = TimeUtil.nowMillis(),
        lastOkAt: Int64? = nil,
        userId: String? = nil,
        note: String = ""
    ) {
        self.id = id
        self.label = label
        self.host = host
        self.scheme = scheme
        self.bearer = bearer
        self.sessionId = sessionId
        self.csrfToken = csrfToken
        self.enabled = enabled
        self.createdAt = createdAt
        self.lastOkAt = lastOkAt
        self.userId = userId
        self.note = note
    }

    enum CodingKeys: String, CodingKey {
        case id, label, host, scheme, bearer, sessionId, csrfToken, enabled, createdAt, lastOkAt, userId, note
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawId = container.value(String.self, .id, "")
        id = rawId.isEmpty ? Ids.randomId() : rawId
        label = container.value(String.self, .label, "账号")
        host = container.value(String.self, .host, "www.yuketang.cn")
        scheme = container.value(String.self, .scheme, "https")
        bearer = container.optional(String.self, .bearer)
        sessionId = container.optional(String.self, .sessionId)
        csrfToken = container.optional(String.self, .csrfToken)
        enabled = container.value(Bool.self, .enabled, true)
        createdAt = container.value(Int64.self, .createdAt, 0)
        lastOkAt = container.optional(Int64.self, .lastOkAt)
        userId = container.optional(String.self, .userId)
        note = container.value(String.self, .note, "")
    }

    var baseUrl: String { "\(scheme)://\(host)" }

    var hasBearer: Bool { bearer?.trimmedNonEmpty != nil }
    var hasSessionCookie: Bool { sessionId?.trimmedNonEmpty != nil }
    var hasCsrf: Bool { csrfToken?.trimmedNonEmpty != nil }

    var hasCredential: Bool { hasBearer || hasSessionCookie }

    /// 强化脱敏展示（对齐 Kotlin `Models.kt`：<=12 字符全掩为 `****`）。
    func maskedCredential() -> String {
        let raw = bearer?.trimmedNonEmpty ?? sessionId?.trimmed ?? ""
        if raw.isEmpty { return "未配置" }
        if raw.count <= 12 { return "****" }
        if raw.count <= 20 {
            return String(raw.prefix(2)) + "…" + String(raw.suffix(2))
        }
        return String(raw.prefix(4)) + "…" + String(raw.suffix(3))
    }
}

// MARK: - 二维码

enum TicketKind: String, Codable, Hashable, CaseIterable, Sendable {
    case DYNAMIC_CHECKIN
    case LESSON_ONLY
    case LOGIN
    case UNKNOWN

    var displayName: String {
        switch self {
        case .DYNAMIC_CHECKIN: return "动态签到码"
        case .LESSON_ONLY: return "静态课堂码"
        case .LOGIN: return "登录二维码"
        case .UNKNOWN: return "未识别文本"
        }
    }

    var symbolName: String {
        switch self {
        case .DYNAMIC_CHECKIN: return "bolt.circle.fill"
        case .LESSON_ONLY: return "book.closed.fill"
        case .LOGIN: return "person.badge.key.fill"
        case .UNKNOWN: return "questionmark.diamond.fill"
        }
    }
}

struct QrTicket: Codable, Hashable, Sendable {
    var raw: String
    var kind: TicketKind
    var url: String?
    var host: String?
    var params: [String: String]
    var lessonId: String?
    var classroomId: String?
    var checkinId: String?

    init(
        raw: String,
        kind: TicketKind,
        url: String? = nil,
        host: String? = nil,
        params: [String: String] = [:],
        lessonId: String? = nil,
        classroomId: String? = nil,
        checkinId: String? = nil
    ) {
        self.raw = raw
        self.kind = kind
        self.url = url
        self.host = host
        self.params = params
        self.lessonId = lessonId
        self.classroomId = classroomId
        self.checkinId = checkinId
    }

    var dynamicCode: String? { params["c"] }
    var timestamp: String? { params["t"] }
    var signature: String? { params["s"] }
    var version: String? { params["v"] }

    /// 动态码时间戳（支持秒级或毫秒级 unix timestamp）。
    var parsedTimestampDate: Date? {
        guard let t = timestamp?.trimmedNonEmpty, let num = Double(t), num > 1_000_000_000 else {
            return nil
        }
        let seconds = num > 10_000_000_000 ? num / 1000.0 : num
        return Date(timeIntervalSince1970: seconds)
    }

    func summary() -> String {
        switch kind {
        case .DYNAMIC_CHECKIN:
            let code = String((dynamicCode ?? "").prefix(8))
            return "动态码 c=\(code)… t=\(timestamp ?? "?")"
        case .LESSON_ONLY:
            return "课堂 lessonId=\(lessonId ?? "?")"
        case .LOGIN:
            return "登录二维码"
        case .UNKNOWN:
            return "未识别: \(String(raw.prefix(40)))"
        }
    }

    var parameterSummary: String {
        var parts: [String] = []
        if let value = dynamicCode { parts.append("c=\(String(value.prefix(12)))") }
        if let value = timestamp { parts.append("t=\(value)") }
        if let value = signature { parts.append("s=\(String(value.prefix(10)))") }
        if let value = version { parts.append("v=\(value)") }
        return parts.isEmpty ? "无 c/t/s 参数" : parts.joined(separator: "  ")
    }
}

// MARK: - ProtocolProfile 契约结构

struct AuthSpec: Codable, Hashable, Sendable {
    var bearerHeader: String
    var bearerPrefix: String
    var cookieNames: [String]
    var csrfCookie: String
    var csrfHeader: String
    var tokenResponseHeaders: [String]

    init(
        bearerHeader: String = "Authorization",
        bearerPrefix: String = "Bearer ",
        cookieNames: [String] = ["sessionid", "csrftoken"],
        csrfCookie: String = "csrftoken",
        csrfHeader: String = "X-CSRFToken",
        tokenResponseHeaders: [String] = ["set-auth", "authorization"]
    ) {
        self.bearerHeader = bearerHeader
        self.bearerPrefix = bearerPrefix
        self.cookieNames = cookieNames
        self.csrfCookie = csrfCookie
        self.csrfHeader = csrfHeader
        self.tokenResponseHeaders = tokenResponseHeaders
    }

    enum CodingKeys: String, CodingKey {
        case bearerHeader, bearerPrefix, cookieNames, csrfCookie, csrfHeader, tokenResponseHeaders
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bearerHeader = container.value(String.self, .bearerHeader, "Authorization")
        bearerPrefix = container.value(String.self, .bearerPrefix, "Bearer ")
        cookieNames = container.value([String].self, .cookieNames, ["sessionid", "csrftoken"])
        csrfCookie = container.value(String.self, .csrfCookie, "csrftoken")
        csrfHeader = container.value(String.self, .csrfHeader, "X-CSRFToken")
        tokenResponseHeaders = container.value([String].self, .tokenResponseHeaders, ["set-auth", "authorization"])
    }

    var effectiveCsrfCookie: String {
        csrfCookie.trimmedNonEmpty ?? "csrftoken"
    }

    var primarySessionCookie: String {
        let csrf = effectiveCsrfCookie
        return cookieNames.first {
            $0.trimmedNonEmpty != nil && $0.caseInsensitiveCompare(csrf) != .orderedSame
        } ?? "sessionid"
    }

    var acceptedSessionCookies: [String] {
        let csrf = effectiveCsrfCookie
        var seen = Set<String>()
        var result: [String] = []
        let candidates = cookieNames.filter {
            $0.trimmedNonEmpty != nil && $0.caseInsensitiveCompare(csrf) != .orderedSame
        } + ["sessionid", "sid"]
        for item in candidates {
            let key = item.lowercased()
            if seen.insert(key).inserted {
                result.append(item)
            }
        }
        return result
    }
}

struct EndpointSpec: Codable, Hashable, Sendable {
    var method: String
    var path: String
    var body: JSONValue?
    var query: [String: String]
    var auth: Bool
    var note: String

    init(
        method: String = "GET",
        path: String = "/",
        body: JSONValue? = nil,
        query: [String: String] = [:],
        auth: Bool = true,
        note: String = ""
    ) {
        self.method = method
        self.path = path
        self.body = body
        self.query = query
        self.auth = auth
        self.note = note
    }

    enum CodingKeys: String, CodingKey {
        case method, path, body, query, auth, note
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        method = container.value(String.self, .method, "GET")
        path = container.value(String.self, .path, "/")
        body = container.optional(JSONValue.self, .body)
        query = container.value([String: String].self, .query, [:])
        auth = container.value(Bool.self, .auth, true)
        note = container.value(String.self, .note, "")
    }
}

struct StrategySpec: Codable, Hashable, Sendable {
    var id: String
    var endpoint: String?
    var appliesTo: [String]
    var requires: [String]
    var vars: [String: JSONValue]
    var note: String

    init(
        id: String,
        endpoint: String? = nil,
        appliesTo: [String] = [],
        requires: [String] = [],
        vars: [String: JSONValue] = [:],
        note: String = ""
    ) {
        self.id = id
        self.endpoint = endpoint
        self.appliesTo = appliesTo
        self.requires = requires
        self.vars = vars
        self.note = note
    }

    enum CodingKeys: String, CodingKey {
        case id, endpoint, appliesTo, requires, vars, note
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.value(String.self, .id, "")
        endpoint = container.optional(String.self, .endpoint)
        appliesTo = container.value([String].self, .appliesTo, [])
        requires = container.value([String].self, .requires, [])
        vars = container.value([String: JSONValue].self, .vars, [:])
        note = container.value(String.self, .note, "")
    }
}

struct QrSpec: Codable, Hashable, Sendable {
    var dynamicKeys: [String]
    var lessonKeys: [String]
    var classroomKeys: [String]
    var checkinKeys: [String]
    var loginPathHints: [String]
    var schemes: [String]
    var allowedUrlHosts: [String]

    init(
        dynamicKeys: [String] = ["c", "t", "s"],
        lessonKeys: [String] = ["lessonId", "lesson_id", "lessonid", "lid"],
        classroomKeys: [String] = ["classroomId", "classroom_id", "classroomid", "cid"],
        checkinKeys: [String] = ["checkinId", "checkin_id", "signId", "sign_id"],
        loginPathHints: [String] = ["login", "qrcode", "scan", "qrconnect"],
        schemes: [String] = ["https", "http", "app", "yuketang", "ykt", "rainclassroom"],
        allowedUrlHosts: [String] = []
    ) {
        self.dynamicKeys = dynamicKeys
        self.lessonKeys = lessonKeys
        self.classroomKeys = classroomKeys
        self.checkinKeys = checkinKeys
        self.loginPathHints = loginPathHints
        self.schemes = schemes
        self.allowedUrlHosts = allowedUrlHosts
    }

    enum CodingKeys: String, CodingKey {
        case dynamicKeys, lessonKeys, classroomKeys, checkinKeys, loginPathHints, schemes, allowedUrlHosts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dynamicKeys = container.value([String].self, .dynamicKeys, ["c", "t", "s"])
        lessonKeys = container.value([String].self, .lessonKeys, ["lessonId", "lesson_id", "lessonid", "lid"])
        classroomKeys = container.value([String].self, .classroomKeys, ["classroomId", "classroom_id", "classroomid", "cid"])
        checkinKeys = container.value([String].self, .checkinKeys, ["checkinId", "checkin_id", "signId", "sign_id"])
        loginPathHints = container.value([String].self, .loginPathHints, ["login", "qrcode", "scan", "qrconnect"])
        schemes = container.value([String].self, .schemes, ["https", "http", "app", "yuketang", "ykt", "rainclassroom"])
        allowedUrlHosts = container.value([String].self, .allowedUrlHosts, [])
    }
}

struct ResultSpec: Codable, Hashable, Sendable {
    var codeField: String
    var altCodeKeys: [String]
    var okCodes: [Int]
    var messageFields: [String]
    var altMessageKeys: [String]
    var alreadyKeywords: [String]
    var authKeywords: [String]
    var expiredKeywords: [String]
    var retryHttpStatus: [Int]

    init(
        codeField: String = "code",
        altCodeKeys: [String] = ["errcode"],
        okCodes: [Int] = [0],
        messageFields: [String] = ["msg", "message"],
        altMessageKeys: [String] = ["errmsg"],
        alreadyKeywords: [String] = ["已签到", "已经签到", "重复签到", "已参与"],
        authKeywords: [String] = ["登录", "未授权", "身份", "token", "会话", "unauthorized"],
        expiredKeywords: [String] = ["失效", "过期", "不存在", "二维码已"],
        retryHttpStatus: [Int] = [408, 425, 429, 500, 502, 503, 504]
    ) {
        self.codeField = codeField
        self.altCodeKeys = altCodeKeys
        self.okCodes = okCodes
        self.messageFields = messageFields
        self.altMessageKeys = altMessageKeys
        self.alreadyKeywords = alreadyKeywords
        self.authKeywords = authKeywords
        self.expiredKeywords = expiredKeywords
        self.retryHttpStatus = retryHttpStatus
    }

    enum CodingKeys: String, CodingKey {
        case codeField, altCodeKeys, okCodes, messageFields, altMessageKeys
        case alreadyKeywords, authKeywords, expiredKeywords, retryHttpStatus
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        codeField = container.value(String.self, .codeField, "code")
        altCodeKeys = container.value([String].self, .altCodeKeys, ["errcode"])
        okCodes = container.value([Int].self, .okCodes, [0])
        messageFields = container.value([String].self, .messageFields, ["msg", "message"])
        altMessageKeys = container.value([String].self, .altMessageKeys, ["errmsg"])
        alreadyKeywords = container.value([String].self, .alreadyKeywords, ["已签到", "已经签到", "重复签到", "已参与"])
        authKeywords = container.value([String].self, .authKeywords, ["登录", "未授权", "身份", "token", "会话", "unauthorized"])
        expiredKeywords = container.value([String].self, .expiredKeywords, ["失效", "过期", "不存在", "二维码已"])
        retryHttpStatus = container.value([Int].self, .retryHttpStatus, [408, 425, 429, 500, 502, 503, 504])
    }

    var allCodeKeys: [String] {
        var seen = Set<String>()
        return ([codeField] + altCodeKeys).compactMap { key -> String? in
            guard let clean = key.trimmedNonEmpty, seen.insert(clean).inserted else { return nil }
            return clean
        }
    }

    var allMessageKeys: [String] {
        var seen = Set<String>()
        return (messageFields + altMessageKeys).compactMap { key -> String? in
            guard let clean = key.trimmedNonEmpty, seen.insert(clean).inserted else { return nil }
            return clean
        }
    }

    func isOkCode(_ code: Int?) -> Bool {
        guard let code else { return false }
        return okCodes.contains(code)
    }
}

struct ProtocolProfile: Codable, Hashable, Sendable {
    var version: Int
    var name: String
    var updatedAt: String
    var defaultEdition: String
    var editions: [Edition]
    var headers: [String: String]
    var userAgent: String
    var auth: AuthSpec
    var endpoints: [String: EndpointSpec]
    var strategies: [StrategySpec]
    var qr: QrSpec
    var result: ResultSpec

    init(
        version: Int = 1,
        name: String = "yuketang",
        updatedAt: String = "",
        defaultEdition: String = "www",
        editions: [Edition] = [],
        headers: [String: String] = [:],
        userAgent: String = "",
        auth: AuthSpec = AuthSpec(),
        endpoints: [String: EndpointSpec] = [:],
        strategies: [StrategySpec] = [],
        qr: QrSpec = QrSpec(),
        result: ResultSpec = ResultSpec()
    ) {
        self.version = version
        self.name = name
        self.updatedAt = updatedAt
        self.defaultEdition = defaultEdition
        self.editions = editions
        self.headers = headers
        self.userAgent = userAgent
        self.auth = auth
        self.endpoints = endpoints
        self.strategies = strategies
        self.qr = qr
        self.result = result
    }

    enum CodingKeys: String, CodingKey {
        case version, name, updatedAt, defaultEdition, editions, headers, userAgent
        case auth, endpoints, strategies, qr, result
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = container.value(Int.self, .version, 1)
        name = container.value(String.self, .name, "yuketang")
        updatedAt = container.value(String.self, .updatedAt, "")
        defaultEdition = container.value(String.self, .defaultEdition, "www")
        editions = container.value([Edition].self, .editions, [])
        headers = container.value([String: String].self, .headers, [:])
        userAgent = container.value(String.self, .userAgent, "")
        auth = container.value(AuthSpec.self, .auth, AuthSpec())
        endpoints = container.value([String: EndpointSpec].self, .endpoints, [:])
        strategies = container.value([StrategySpec].self, .strategies, [])
        qr = container.value(QrSpec.self, .qr, QrSpec())
        result = container.value(ResultSpec.self, .result, ResultSpec())
    }

    func orderedStrategies(kind: TicketKind) -> [StrategySpec] {
        strategies.filter { spec in
            spec.appliesTo.isEmpty || spec.appliesTo.contains(kind.rawValue)
        }
    }

    func edition(id: String) -> Edition? {
        editions.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }

    func defaultEditionSpec() -> Edition {
        edition(id: defaultEdition) ?? editions.first ?? Edition.WWW
    }

    func editionForHost(_ host: String) -> Edition? {
        editions.first { $0.host.caseInsensitiveCompare(host) == .orderedSame }
    }

    /// 校验二维码直连 URL 是否属于同源或白名单域名与安全协议（100% 对齐 `core/Profile.kt`）。
    /// 返回 `nil` 表示放行；非空字符串为拦截原因。
    func validateQrUrl(_ url: String, account: Account? = nil) -> String? {
        guard let scheme = QrParser.extractScheme(url)?.lowercased() else {
            return "URL 缺少合法协议"
        }
        if scheme != "https" && scheme != "http" {
            return "不允许的协议: \(scheme)"
        }
        guard let range = url.range(of: "://") else {
            return "URL 缺少合法协议"
        }
        let afterScheme = String(url[range.upperBound...])
        let authority: String
        if let end = afterScheme.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            authority = String(afterScheme[..<end])
        } else {
            authority = afterScheme
        }
        if authority.isEmpty {
            return "URL 缺少主机名"
        }
        if authority.contains("@") || authority.contains("\\") || authority.contains(where: { $0.isWhitespace }) {
            return "URL 主机段包含不安全字符"
        }
        guard let hostPort = QrParser.extractHost(url) else {
            return "无法解析 URL 主机名"
        }
        let normalized = ProtocolProfile.normalizeHostPort(scheme: scheme, rawHost: hostPort)

        var allowedHttps = Set<String>()
        var allowedHttp = Set<String>()

        for edition in editions {
            let edScheme = edition.scheme.lowercased()
            if edScheme == "https" {
                allowedHttps.insert(ProtocolProfile.normalizeHostPort(scheme: "https", rawHost: edition.host))
            } else if edScheme == "http" {
                allowedHttp.insert(ProtocolProfile.normalizeHostPort(scheme: "http", rawHost: edition.host))
            }
        }
        for allowedHost in qr.allowedUrlHosts {
            if let clean = allowedHost.trimmedNonEmpty {
                allowedHttps.insert(ProtocolProfile.normalizeHostPort(scheme: "https", rawHost: clean))
            }
        }
        if let account, let accHost = account.host.trimmedNonEmpty {
            let accScheme = account.scheme.lowercased()
            if accScheme == "https" {
                allowedHttps.insert(ProtocolProfile.normalizeHostPort(scheme: "https", rawHost: accHost))
            } else if accScheme == "http" {
                allowedHttp.insert(ProtocolProfile.normalizeHostPort(scheme: "http", rawHost: accHost))
            }
        }

        switch scheme {
        case "https":
            return allowedHttps.contains(normalized) ? nil : "域名 \(hostPort) 不在白名单中"
        case "http":
            return allowedHttp.contains(normalized) ? nil : "拒绝向未显式允许的明文 HTTP 主机 \(hostPort) 发送凭据"
        default:
            return "不允许的协议: \(scheme)"
        }
    }

    func isAllowedQrUrl(_ url: String, account: Account? = nil) -> Bool {
        validateQrUrl(url, account: account) == nil
    }

    private static func normalizeHostPort(scheme: String, rawHost: String) -> String {
        let lower = rawHost.trimmed.lowercased()
        if scheme == "https" && lower.hasSuffix(":443") {
            return String(lower.dropLast(4))
        }
        if scheme == "http" && lower.hasSuffix(":80") {
            return String(lower.dropLast(3))
        }
        return lower
    }

    static func parse(data: Data) throws -> ProtocolProfile {
        try JSONDecoder().decode(ProtocolProfile.self, from: data)
    }

    static func parse(text: String) throws -> ProtocolProfile {
        try parse(data: Data(text.utf8))
    }
}

// MARK: - 统一响应视图与会话回填

struct AuthUpdate: Codable, Hashable, Sendable {
    var bearer: String?
    var sessionId: String?
    var csrfToken: String?

    init(bearer: String? = nil, sessionId: String? = nil, csrfToken: String? = nil) {
        self.bearer = bearer
        self.sessionId = sessionId
        self.csrfToken = csrfToken
    }

    var isEmpty: Bool {
        (bearer?.trimmedNonEmpty == nil)
            && (sessionId?.trimmedNonEmpty == nil)
            && (csrfToken?.trimmedNonEmpty == nil)
    }

    /// 将新会话合入账号；仅在 `markOk == true`（成功响应）时更新 `lastOkAt`。
    func applyTo(_ account: Account, markOk: Bool = false) -> Account {
        var copy = account
        if let bearer = bearer?.trimmedNonEmpty {
            copy.bearer = bearer
        }
        if let sessionId = sessionId?.trimmedNonEmpty {
            copy.sessionId = sessionId
        }
        if let csrfToken = csrfToken?.trimmedNonEmpty {
            copy.csrfToken = csrfToken
        }
        if markOk {
            copy.lastOkAt = TimeUtil.nowMillis()
        }
        return copy
    }
}

struct ApiResult: Sendable {
    /// HTTP 状态码；`-1` 表示网络层失败，`-2` 表示本地配置缺失。
    var httpStatus: Int
    var body: String
    var json: [String: JSONValue]?
    var code: Int?
    var message: String?
    var elapsedMs: Int64
    var auth: AuthUpdate?
    var ok: Bool

    init(
        httpStatus: Int,
        body: String,
        json: [String: JSONValue]? = nil,
        code: Int? = nil,
        message: String? = nil,
        elapsedMs: Int64 = 0,
        auth: AuthUpdate? = nil,
        ok: Bool? = nil
    ) {
        self.httpStatus = httpStatus
        self.body = body
        self.json = json
        self.code = code
        self.message = message
        self.elapsedMs = elapsedMs
        self.auth = auth
        self.ok = ok ?? ((200...299).contains(httpStatus) && code == 0)
    }

    func data() -> [String: JSONValue]? {
        json?["data"]?.objectValue
    }

    func dataOf(_ key: String) -> JSONValue? {
        data()?[key]
    }
}

// MARK: - 签到状态、结果与选项

enum SignState: String, Codable, Hashable, CaseIterable, Sendable {
    case SUCCESS
    case ALREADY
    case DRY_RUN
    case FAILED
    case AUTH_REQUIRED
    case TICKET_EXPIRED
    case NO_CONTEXT
    case ERROR

    var displayName: String {
        switch self {
        case .SUCCESS: return "签到成功"
        case .ALREADY: return "已签到"
        case .DRY_RUN: return "演练轨迹"
        case .FAILED: return "策略拒绝"
        case .AUTH_REQUIRED: return "需要登录"
        case .TICKET_EXPIRED: return "码已失效"
        case .NO_CONTEXT: return "缺少课堂"
        case .ERROR: return "网络异常"
        }
    }

    var symbolName: String {
        switch self {
        case .SUCCESS: return "checkmark.circle.fill"
        case .ALREADY: return "checkmark.seal.fill"
        case .DRY_RUN: return "waveform.path.ecg"
        case .FAILED: return "xmark.octagon.fill"
        case .AUTH_REQUIRED: return "person.badge.key.fill"
        case .TICKET_EXPIRED: return "clock.badge.xmark.fill"
        case .NO_CONTEXT: return "questionmark.folder.fill"
        case .ERROR: return "wifi.exclamationmark"
        }
    }

    var isSuccess: Bool { self == .SUCCESS || self == .ALREADY }
}

struct StrategyAttempt: Codable, Hashable, Sendable {
    var strategy: String
    var httpStatus: Int?
    var code: Int?
    var message: String?
    var ok: Bool
    var requestLine: String
    var requestBody: String?
    var responseBody: String?
    var elapsedMs: Int64

    init(
        strategy: String,
        httpStatus: Int? = nil,
        code: Int? = nil,
        message: String? = nil,
        ok: Bool = false,
        requestLine: String = "",
        requestBody: String? = nil,
        responseBody: String? = nil,
        elapsedMs: Int64 = 0
    ) {
        self.strategy = strategy
        self.httpStatus = httpStatus
        self.code = code
        self.message = message
        self.ok = ok
        self.requestLine = requestLine
        self.requestBody = requestBody
        self.responseBody = responseBody
        self.elapsedMs = elapsedMs
    }
}

/// 单账号签到结果。
/// **安全约束**：自定义 `CodingKeys` 永久排除 `refreshedAccount`，保证导出 JSON 绝不泄露任何凭据！
struct SignResult: Codable, Identifiable, Hashable, Sendable {
    var accountId: String
    var label: String
    var state: SignState
    var message: String
    var strategy: String?
    var lessonId: String?
    var attempts: [StrategyAttempt]
    /// 仅在服务端确实回传并变更会话凭据时由引擎内部赋值；绝不参与 Codable 序列化。
    var refreshedAccount: Account?

    enum CodingKeys: String, CodingKey {
        case accountId, label, state, message, strategy, lessonId, attempts
    }

    init(
        accountId: String,
        label: String,
        state: SignState,
        message: String,
        strategy: String? = nil,
        lessonId: String? = nil,
        attempts: [StrategyAttempt] = [],
        refreshedAccount: Account? = nil
    ) {
        self.accountId = accountId
        self.label = label
        self.state = state
        self.message = message
        self.strategy = strategy
        self.lessonId = lessonId
        self.attempts = attempts
        self.refreshedAccount = refreshedAccount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountId = try container.decode(String.self, forKey: .accountId)
        label = try container.decode(String.self, forKey: .label)
        state = try container.decode(SignState.self, forKey: .state)
        message = try container.decode(String.self, forKey: .message)
        strategy = try container.decodeIfPresent(String.self, forKey: .strategy)
        lessonId = try container.decodeIfPresent(String.self, forKey: .lessonId)
        attempts = try container.decodeIfPresent([StrategyAttempt].self, forKey: .attempts) ?? []
        refreshedAccount = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accountId, forKey: .accountId)
        try container.encode(label, forKey: .label)
        try container.encode(state, forKey: .state)
        try container.encode(message, forKey: .message)
        try container.encodeIfPresent(strategy, forKey: .strategy)
        try container.encodeIfPresent(lessonId, forKey: .lessonId)
        try container.encode(attempts, forKey: .attempts)
    }

    var id: String { accountId }
    var ok: Bool { state == .SUCCESS || state == .ALREADY }

    var attemptsElapsedMs: Int64 {
        attempts.reduce(Int64(0)) { $0 + max($1.elapsedMs, 0) }
    }
}

struct SignOptions: Equatable, Hashable, Sendable {
    var concurrency: Int
    var maxAttemptsPerStrategy: Int
    var baseBackoffMs: Int64
    var stopWhenTicketExpired: Bool
    var dryRun: Bool
    var strategyIds: [String]?
    var staggerMs: Int64

    init(
        concurrency: Int = 4,
        maxAttemptsPerStrategy: Int = 3,
        baseBackoffMs: Int64 = 800,
        stopWhenTicketExpired: Bool = true,
        dryRun: Bool = false,
        strategyIds: [String]? = nil,
        staggerMs: Int64 = 60
    ) {
        self.concurrency = min(max(concurrency, 1), 32)
        self.maxAttemptsPerStrategy = min(max(maxAttemptsPerStrategy, 1), 10)
        self.baseBackoffMs = min(max(baseBackoffMs, 0), 30_000)
        self.stopWhenTicketExpired = stopWhenTicketExpired
        self.dryRun = dryRun
        self.strategyIds = strategyIds
        self.staggerMs = min(max(staggerMs, 0), 10_000)
    }
}

struct SignBatchReport: Codable, Hashable, Sendable {
    var results: [SignResult]
    var startedAt: Int64
    var finishedAt: Int64
    var ticket: QrTicket

    var successCount: Int { results.filter { $0.ok }.count }
    var dryRunCount: Int { results.filter { $0.state == .DRY_RUN }.count }
    var failedCount: Int { results.filter { !$0.ok && $0.state != .DRY_RUN }.count }
    var elapsedMs: Int64 { max(finishedAt - startedAt, 0) }

    func count(for state: SignState) -> Int {
        results.filter { $0.state == state }.count
    }

    var sessionUpdates: [Account] {
        results.compactMap { $0.refreshedAccount }
    }
}

/// 导出给分享 / 归档的 JSON 结构（严格零凭据）。
struct SignExport: Codable, Sendable {
    var exportedAt: Int64
    var profileName: String
    var profileVersion: Int
    var ticket: QrTicket
    var results: [SignResult]
}

// MARK: - 登录轮询

enum LoginState: String, Codable, Hashable, Sendable {
    case PENDING
    case SCANNED
    case NEED_CODE
    case AUTHORIZED
    case EXPIRED
    case ERROR

    var displayName: String {
        switch self {
        case .PENDING: return "等待微信扫码"
        case .SCANNED: return "已扫码，请在微信确认"
        case .NEED_CODE: return "需要 4 位验证码"
        case .AUTHORIZED: return "登录成功"
        case .EXPIRED: return "二维码已失效"
        case .ERROR: return "登录异常"
        }
    }
}

struct LoginPoll: Codable, Hashable, Sendable {
    var state: LoginState
    var message: String
    var loginToken: String?
    var qrContent: String?
    var account: Account?

    init(
        state: LoginState,
        message: String,
        loginToken: String? = nil,
        qrContent: String? = nil,
        account: Account? = nil
    ) {
        self.state = state
        self.message = message
        self.loginToken = loginToken
        self.qrContent = qrContent
        self.account = account
    }
}
