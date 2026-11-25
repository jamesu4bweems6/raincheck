import Foundation

/// 严格类型化、并发安全的 JSON 值模型，避免 `NSNumber` / `CFBoolean` 桥接陷阱。
enum TemplateValue: Codable, Hashable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([TemplateValue])
    case object([String: TemplateValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let boolVal = try? container.decode(Bool.self) {
            self = .bool(boolVal)
        } else if let intVal = try? container.decode(Int.self) {
            self = .int(intVal)
        } else if let doubleVal = try? container.decode(Double.self) {
            self = .double(doubleVal)
        } else if let stringVal = try? container.decode(String.self) {
            self = .string(stringVal)
        } else if let arrayVal = try? container.decode([TemplateValue].self) {
            self = .array(arrayVal)
        } else if let objectVal = try? container.decode([String: TemplateValue].self) {
            self = .object(objectVal)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value for TemplateValue"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    /// 安全提取字符串（排除 `.null` / `.array` / `.object`）。
    var stringValue: String? {
        switch self {
        case .string(let v):
            return v
        case .int(let v):
            return String(v)
        case .double(let v):
            return String(v)
        case .bool(let v):
            return v ? "true" : "false"
        case .array, .object, .null:
            return nil
        }
    }

    /// 安全提取整数（严格拒绝 `.bool` 与 `.null`，杜绝 `false == 0` 误判）。
    var intValue: Int? {
        switch self {
        case .int(let v):
            return v
        case .string(let v):
            return Int(v.trimmingCharacters(in: .whitespacesAndNewlines))
        case .double(let v):
            guard v.isFinite, v.rounded() == v,
                  v >= Double(Int.min), v <= Double(Int.max) else {
                return nil
            }
            return Int(v)
        case .bool, .array, .object, .null:
            return nil
        }
    }

    /// 安全提取布尔值（严格只接受 `.bool`）。
    var boolValue: Bool? {
        switch self {
        case .bool(let v):
            return v
        default:
            return nil
        }
    }

    var objectValue: [String: TemplateValue]? {
        if case .object(let dict) = self {
            return dict
        }
        return nil
    }

    var arrayValue: [TemplateValue]? {
        if case .array(let arr) = self {
            return arr
        }
        return nil
    }

    /// 将 `JSONSerialization` 产物安全转换为 `TemplateValue`，显式区分 `CFBoolean` 与数字。
    static func fromFoundationObject(_ raw: Any) -> TemplateValue {
        if raw is NSNull {
            return .null
        }
        if let dict = raw as? [String: Any] {
            var mapped: [String: TemplateValue] = [:]
            mapped.reserveCapacity(dict.count)
            for (k, v) in dict {
                mapped[k] = fromFoundationObject(v)
            }
            return .object(mapped)
        }
        if let array = raw as? [Any] {
            return .array(array.map { fromFoundationObject($0) })
        }
        if let stringVal = raw as? String {
            return .string(stringVal)
        }
        if let number = raw as? NSNumber {
            if CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            let objCType = String(cString: number.objCType)
            if objCType == "f" || objCType == "d" {
                return .double(number.doubleValue)
            }
            return .int(number.intValue)
        }
        return .null
    }
}

extension TemplateValue: ExpressibleByStringLiteral {
    init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension TemplateValue: ExpressibleByIntegerLiteral {
    init(integerLiteral value: Int) {
        self = .int(value)
    }
}

extension TemplateValue: ExpressibleByFloatLiteral {
    init(floatLiteral value: Double) {
        self = .double(value)
    }
}

extension TemplateValue: ExpressibleByBooleanLiteral {
    init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

extension TemplateValue: ExpressibleByArrayLiteral {
    init(arrayLiteral elements: TemplateValue...) {
        self = .array(elements)
    }
}

extension TemplateValue: ExpressibleByDictionaryLiteral {
    init(dictionaryLiteral elements: (String, TemplateValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

extension TemplateValue: ExpressibleByNilLiteral {
    init(nilLiteral: ()) {
        self = .null
    }
}

extension Dictionary where Key == String, Value == TemplateValue {
    func firstNonBlankString(_ keys: String...) -> String? {
        firstNonBlankString(keys)
    }

    func firstNonBlankString(_ keys: [String]) -> String? {
        for key in keys {
            if let raw = self[key]?.stringValue,
               !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return raw
            }
        }
        return nil
    }
}

struct AuthSpec: Codable, Hashable, Sendable {
    let bearerHeader: String
    let bearerPrefix: String
    let cookieNames: [String]
    let csrfCookie: String
    let csrfHeader: String
    let tokenResponseHeaders: [String]

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
        case bearerHeader
        case bearerPrefix
        case cookieNames
        case csrfCookie
        case csrfHeader
        case tokenResponseHeaders
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.bearerHeader = try c.decodeIfPresent(String.self, forKey: .bearerHeader) ?? "Authorization"
        self.bearerPrefix = try c.decodeIfPresent(String.self, forKey: .bearerPrefix) ?? "Bearer "
        self.cookieNames = try c.decodeIfPresent([String].self, forKey: .cookieNames) ?? ["sessionid", "csrftoken"]
        self.csrfCookie = try c.decodeIfPresent(String.self, forKey: .csrfCookie) ?? "csrftoken"
        self.csrfHeader = try c.decodeIfPresent(String.self, forKey: .csrfHeader) ?? "X-CSRFToken"
        self.tokenResponseHeaders = try c.decodeIfPresent([String].self, forKey: .tokenResponseHeaders) ?? ["set-auth", "authorization"]
    }

    func effectiveCsrfCookie() -> String {
        let trimmed = csrfCookie.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "csrftoken" : trimmed
    }

    func primarySessionCookie() -> String {
        let csrf = effectiveCsrfCookie()
        return cookieNames.first {
            let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && trimmed.caseInsensitiveCompare(csrf) != .orderedSame
        } ?? "sessionid"
    }

    func acceptedSessionCookies() -> [String] {
        let csrf = effectiveCsrfCookie()
        let configured = cookieNames.filter {
            let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && trimmed.caseInsensitiveCompare(csrf) != .orderedSame
        }
        var seen = Set<String>()
        var result: [String] = []
        for candidate in configured + ["sessionid", "sid"] {
            let key = candidate.lowercased()
            if seen.insert(key).inserted {
                result.append(candidate)
            }
        }
        return result
    }
}

struct EndpointSpec: Codable, Hashable, Sendable {
    let method: String
    let path: String
    let body: [String: TemplateValue]?
    let query: [String: String]
    let headers: [String: String]
    let auth: Bool
    let note: String

    init(
        method: String,
        path: String,
        body: [String: TemplateValue]? = nil,
        query: [String: String] = [:],
        headers: [String: String] = [:],
        auth: Bool = true,
        note: String = ""
    ) {
        self.method = method
        self.path = path
        self.body = body
        self.query = query
        self.headers = headers
        self.auth = auth
        self.note = note
    }

    enum CodingKeys: String, CodingKey {
        case method
        case path
        case body
        case query
        case headers
        case auth
        case note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.method = try c.decode(String.self, forKey: .method)
        self.path = try c.decode(String.self, forKey: .path)
        self.body = try c.decodeIfPresent([String: TemplateValue].self, forKey: .body)
        self.query = try c.decodeIfPresent([String: String].self, forKey: .query) ?? [:]
        self.headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        self.auth = try c.decodeIfPresent(Bool.self, forKey: .auth) ?? true
        self.note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    }
}

struct StrategySpec: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let endpoint: String?
    let appliesTo: [String]
    let requires: [String]
    let vars: [String: TemplateValue]
    let note: String

    init(
        id: String,
        endpoint: String? = nil,
        appliesTo: [String] = [],
        requires: [String] = [],
        vars: [String: TemplateValue] = [:],
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
        case id
        case endpoint
        case appliesTo
        case requires
        case vars
        case note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.endpoint = try c.decodeIfPresent(String.self, forKey: .endpoint)
        self.appliesTo = try c.decodeIfPresent([String].self, forKey: .appliesTo) ?? []
        self.requires = try c.decodeIfPresent([String].self, forKey: .requires) ?? []
        self.vars = try c.decodeIfPresent([String: TemplateValue].self, forKey: .vars) ?? [:]
        self.note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    }
}

struct QrSpec: Codable, Hashable, Sendable {
    let dynamicKeys: [String]
    let lessonKeys: [String]
    let classroomKeys: [String]
    let checkinKeys: [String]
    let loginPathHints: [String]
    let schemes: [String]
    let allowedUrlHosts: [String]

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
        case dynamicKeys
        case lessonKeys
        case classroomKeys
        case checkinKeys
        case loginPathHints
        case schemes
        case allowedUrlHosts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.dynamicKeys = try c.decodeIfPresent([String].self, forKey: .dynamicKeys) ?? ["c", "t", "s"]
        self.lessonKeys = try c.decodeIfPresent([String].self, forKey: .lessonKeys) ?? ["lessonId", "lesson_id", "lessonid", "lid"]
        self.classroomKeys = try c.decodeIfPresent([String].self, forKey: .classroomKeys) ?? ["classroomId", "classroom_id", "classroomid", "cid"]
        self.checkinKeys = try c.decodeIfPresent([String].self, forKey: .checkinKeys) ?? ["checkinId", "checkin_id", "signId", "sign_id"]
        self.loginPathHints = try c.decodeIfPresent([String].self, forKey: .loginPathHints) ?? ["login", "qrcode", "scan", "qrconnect"]
        self.schemes = try c.decodeIfPresent([String].self, forKey: .schemes) ?? ["https", "http", "app", "yuketang", "ykt", "rainclassroom"]
        self.allowedUrlHosts = try c.decodeIfPresent([String].self, forKey: .allowedUrlHosts) ?? []
    }
}

struct ResultSpec: Codable, Hashable, Sendable {
    let codeField: String
    let altCodeKeys: [String]
    let okCodes: [Int]
    let messageFields: [String]
    let altMessageKeys: [String]
    let alreadyKeywords: [String]
    let authKeywords: [String]
    let expiredKeywords: [String]
    let retryHttpStatus: [Int]

    init(
        codeField: String = "code",
        altCodeKeys: [String] = ["errcode", "error_code", "status_code"],
        okCodes: [Int] = [0],
        messageFields: [String] = ["msg", "message"],
        altMessageKeys: [String] = ["errmsg", "errormsg", "detail", "error"],
        alreadyKeywords: [String] = ["已签到", "已经签到", "重复签到", "已参与"],
        authKeywords: [String] = ["登录", "登陆", "未授权", "身份", "token", "会话", "unauthorized", "unauthenticated"],
        expiredKeywords: [String] = ["失效", "过期", "不存在", "二维码已", "dynamic qr check in refused", "qr code expired", "expired"],
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
        case codeField
        case altCodeKeys
        case okCodes
        case messageFields
        case altMessageKeys
        case alreadyKeywords
        case authKeywords
        case expiredKeywords
        case retryHttpStatus
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.codeField = try c.decodeIfPresent(String.self, forKey: .codeField) ?? "code"
        self.altCodeKeys = try c.decodeIfPresent([String].self, forKey: .altCodeKeys) ?? ["errcode", "error_code", "status_code"]
        self.okCodes = try c.decodeIfPresent([Int].self, forKey: .okCodes) ?? [0]
        self.messageFields = try c.decodeIfPresent([String].self, forKey: .messageFields) ?? ["msg", "message"]
        self.altMessageKeys = try c.decodeIfPresent([String].self, forKey: .altMessageKeys) ?? ["errmsg", "errormsg", "detail", "error"]
        self.alreadyKeywords = try c.decodeIfPresent([String].self, forKey: .alreadyKeywords) ?? ["已签到", "已经签到", "重复签到", "已参与"]
        self.authKeywords = try c.decodeIfPresent([String].self, forKey: .authKeywords) ?? ["登录", "登陆", "未授权", "身份", "token", "会话", "unauthorized", "unauthenticated"]
        self.expiredKeywords = try c.decodeIfPresent([String].self, forKey: .expiredKeywords) ?? ["失效", "过期", "不存在", "二维码已", "dynamic qr check in refused", "qr code expired", "expired"]
        self.retryHttpStatus = try c.decodeIfPresent([Int].self, forKey: .retryHttpStatus) ?? [408, 425, 429, 500, 502, 503, 504]
    }

    func allCodeKeys() -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for key in [codeField] + altCodeKeys {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && seen.insert(trimmed).inserted {
                result.append(trimmed)
            }
        }
        return result
    }

    func allMessageKeys() -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for key in messageFields + altMessageKeys {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && seen.insert(trimmed).inserted {
                result.append(trimmed)
            }
        }
        return result
    }

    func isOkCode(_ code: Int?) -> Bool {
        guard let code else { return false }
        return okCodes.contains(code)
    }
}

/// 协议配置主模型（与 `protocol/profile.json` 严格一一对应）。
struct ProtocolProfile: Codable, Hashable, Sendable {
    let version: Int
    let name: String
    let updatedAt: String
    let defaultEdition: String
    let editions: [Edition]
    let headers: [String: String]
    let userAgent: String
    let auth: AuthSpec
    let endpoints: [String: EndpointSpec]
    let strategies: [StrategySpec]
    let qr: QrSpec
    let result: ResultSpec

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
        case version
        case name
        case updatedAt
        case defaultEdition
        case editions
        case headers
        case userAgent
        case auth
        case endpoints
        case strategies
        case qr
        case result
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? "yuketang"
        self.updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
        self.defaultEdition = try c.decodeIfPresent(String.self, forKey: .defaultEdition) ?? "www"
        self.editions = try c.decodeIfPresent([Edition].self, forKey: .editions) ?? []
        self.headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        self.userAgent = try c.decodeIfPresent(String.self, forKey: .userAgent) ?? ""
        self.auth = try c.decodeIfPresent(AuthSpec.self, forKey: .auth) ?? AuthSpec()
        self.endpoints = try c.decodeIfPresent([String: EndpointSpec].self, forKey: .endpoints) ?? [:]
        self.strategies = try c.decodeIfPresent([StrategySpec].self, forKey: .strategies) ?? []
        self.qr = try c.decodeIfPresent(QrSpec.self, forKey: .qr) ?? QrSpec()
        self.result = try c.decodeIfPresent(ResultSpec.self, forKey: .result) ?? ResultSpec()
    }

    func endpoint(_ name: String) -> EndpointSpec? {
        endpoints[name]
    }

    func edition(_ id: String) -> Edition? {
        editions.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }

    func defaultEditionSpec() -> Edition {
        edition(defaultEdition) ?? editions.first ?? Edition.www
    }

    func editionForHost(_ host: String) -> Edition? {
        editions.first { $0.host.caseInsensitiveCompare(host) == .orderedSame }
    }

    func orderedStrategies(for kind: TicketKind) -> [StrategySpec] {
        strategies.filter { $0.appliesTo.isEmpty || $0.appliesTo.contains(kind.rawValue) }
    }
}

/// 协议配置加载器与完整内置兜底定义。
enum ProtocolCatalog {
    static func loadBundled(bundle: Bundle = .main) -> ProtocolProfile {
        let candidates = ["protocol_profile", "profile"]
        for resource in candidates {
            if let url = bundle.url(forResource: resource, withExtension: "json"),
               let data = try? Data(contentsOf: url),
               let profile = try? load(from: data) {
                return profile
            }
        }
        return fallback
    }

    static func load(from data: Data) throws -> ProtocolProfile {
        let decoder = JSONDecoder()
        return try decoder.decode(ProtocolProfile.self, from: data)
    }

    static let fallback: ProtocolProfile = ProtocolProfile(
        version: 1,
        name: "yuketang",
        updatedAt: "2026-11-24",
        defaultEdition: "www",
        editions: Edition.presets,
        headers: [
            "xtbz": "ykt",
            "X-Client": "web",
            "Accept": "application/json, text/plain, */*"
        ],
        userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36",
        auth: AuthSpec(
            bearerHeader: "Authorization",
            bearerPrefix: "Bearer ",
            cookieNames: ["sessionid", "csrftoken"],
            csrfCookie: "csrftoken",
            csrfHeader: "X-CSRFToken",
            tokenResponseHeaders: ["set-auth", "authorization"]
        ),
        endpoints: [
            "me": EndpointSpec(
                method: "GET",
                path: "/api/v3/user/basic-info",
                auth: true
            ),
            "loginPre": EndpointSpec(
                method: "GET",
                path: "/api/v3/user/login/pre-info",
                auth: false,
                note: "外部桌面端脚本推断，未经实网抓包验证"
            ),
            "loginWait": EndpointSpec(
                method: "POST",
                path: "/api/v3/user/login/wait-for-scan",
                body: ["token": .string("{loginToken}")],
                auth: false,
                note: "外部桌面端脚本推断，未经实网抓包验证"
            ),
            "loginPoll": EndpointSpec(
                method: "POST",
                path: "/api/v3/user/login",
                body: ["token": .string("{loginToken}")],
                auth: false,
                note: "外部桌面端脚本推断，未经实网抓包验证"
            ),
            "loginCode": EndpointSpec(
                method: "POST",
                path: "/api/v3/user/login/login-with-code",
                body: ["token": .string("{loginToken}"), "code": .string("{code}")],
                auth: false,
                note: "外部桌面端脚本推断，未经实网抓包验证"
            ),
            "phoneSendSms": EndpointSpec(
                method: "POST",
                path: "/pc/login/send_sms_login_code/",
                body: [
                    "mobile": .string("{mobile}"),
                    "login": .bool(true),
                    "ticket": .string("{ticket}"),
                    "randstr": .string("{randstr}"),
                    "hcaptcha_token": .string("{hcaptchaToken}")
                ],
                auth: false,
                note: "雨课堂 Web PC 端发送短信验证码接口（保留末尾斜杠；IPA 1.3.6 移动端对应 /api/v3/user/code/send）"
            ),
            "phoneVerifyLogin": EndpointSpec(
                method: "POST",
                path: "/pc/login/verify_pwd_login/",
                body: [
                    "type": .string("PC"),
                    "name": .string("{mobile}"),
                    "pwd": .string("{code}")
                ],
                auth: false,
                note: "雨课堂 Web PC 端手机号+短信验证码登录接口（保留末尾斜杠，Set-Cookie 下发 sessionid/csrftoken；IPA 1.3.6 移动端对应 /api/v3/user/login/app）"
            ),
            "activeLesson": EndpointSpec(
                method: "GET",
                path: "/api/v3/classroom/on-lesson-upcoming-exam",
                auth: true
            ),
            "checkinList": EndpointSpec(
                method: "POST",
                path: "/api/v3/lesson/checkin-list",
                body: ["lesson_id": .string("{lessonId}"), "page": .int(0), "limit": .int(20)],
                auth: true,
                note: "IPA 实证属教师端 remote_control POST 接口（postSignList），非学生端 GET"
            ),
            "checkinDetail": EndpointSpec(
                method: "POST",
                path: "/api/v3/lesson/checkin/detail",
                body: ["lesson_id": .string("{lessonId}"), "checkin_id": .string("{checkinId}")],
                auth: true,
                note: "IPA 实证属教师端 remote_control POST 接口（postSignDetail），非学生端 GET"
            ),
            "lessonBasic": EndpointSpec(
                method: "GET",
                path: "/api/v3/lesson/basic-info",
                query: ["lesson_id": "{lessonId}"],
                auth: true,
                note: "IPA 实证查询参数名为 lesson_id"
            ),
            "appScan": EndpointSpec(
                method: "POST",
                path: "/api/v3/app/scan",
                body: ["url": .string("{qrRaw}")],
                headers: ["x-client": "app"],
                auth: true,
                note: "IPA 1.3.6 ARM64 实证：官方扫码第一步，提交原始二维码字符串由服务端校验动态签名并返回 data.type/data.value"
            ),
            "checkinAppScan": EndpointSpec(
                method: "POST",
                path: "/api/v3/lesson/checkin",
                body: [
                    "source": .int(21),
                    "lessonId": .string("{lessonId}"),
                    "joinIfNotIn": .bool(true)
                ],
                headers: ["x-client": "app"],
                auth: true,
                note: "IPA 1.3.6 ARM64 实证：HmsScanPage._postLessonCheckin 第二步，携带 source=21 与 joinIfNotIn=true"
            ),
            "checkinTicket": EndpointSpec(
                method: "POST",
                path: "/api/v3/lesson/checkin",
                body: [
                    "lessonId": .string("{lessonId}"),
                    "source": .string("{source}"),
                    "ticket": .string("{c}"),
                    "t": .string("{t}"),
                    "s": .string("{s}")
                ],
                auth: true,
                note: "路径获 IPA 实证；source/ticket/t/s 请求体由外部桌面端脚本推断"
            ),
            "checkinDesktop": EndpointSpec(
                method: "POST",
                path: "/api/v3/lesson/checkin",
                body: ["lessonId": .string("{lessonId}"), "source": .int(1)],
                auth: true
            ),
            "checkinWeb": EndpointSpec(
                method: "POST",
                path: "/api/lesson/web_check_in",
                body: ["lessonId": .string("{lessonId}"), "source": .int(1)],
                auth: true
            ),
            "locationEligibility": EndpointSpec(
                method: "GET",
                path: "/api/v3/lesson/location-checkin/eligibility",
                query: ["lessonId": "{lessonId}"],
                auth: true,
                note: "学生端定位签到资格查询（需登录态，尚未接入自动签到引擎）"
            ),
            "locationPreview": EndpointSpec(
                method: "GET",
                path: "/api/v3/lesson/location-checkin/preview",
                query: ["lessonId": "{lessonId}"],
                auth: true,
                note: "学生端定位签到预览（尚未接入自动签到引擎）"
            ),
            "locationSession": EndpointSpec(
                method: "POST",
                path: "/api/v3/lesson/location-checkin/session",
                body: ["lessonId": .string("{lessonId}")],
                auth: true,
                note: "IPA 实证属教师端创建定位签到会话接口（非学生端流程）"
            ),
            "locationUpdateSession": EndpointSpec(
                method: "POST",
                path: "/api/v3/location-checkin/update-session",
                body: ["lessonId": .string("{lessonId}")],
                auth: true,
                note: "IPA 实证教师端更新定位签到会话接口（路径不含 /lesson/，非学生端流程）"
            ),
            "locationSubmit": EndpointSpec(
                method: "POST",
                path: "/api/v3/lesson/location-checkin/submit",
                body: [
                    "lessonId": .string("{lessonId}"),
                    "latitude": .string("{latitude}"),
                    "longitude": .string("{longitude}"),
                    "accuracy": .string("{accuracy}")
                ],
                auth: true,
                note: "学生端定位签到提交（尚未接入自动签到引擎）"
            )
        ],
        strategies: [
            StrategySpec(
                id: "DYN_TICKET_14",
                endpoint: "checkinTicket",
                appliesTo: ["DYNAMIC_CHECKIN"],
                requires: ["lessonId", "c"],
                vars: ["source": .int(14)],
                note: "PC/桌面端来源，公开实现里成功率最高（待实网验证）"
            ),
            StrategySpec(
                id: "DYN_TICKET_5",
                endpoint: "checkinTicket",
                appliesTo: ["DYNAMIC_CHECKIN"],
                requires: ["lessonId", "c"],
                vars: ["source": .int(5)],
                note: "小程序来源，部分校区只认这个（待实网验证）"
            ),
            StrategySpec(
                id: "LESSON_DESKTOP",
                endpoint: "checkinDesktop",
                appliesTo: ["DYNAMIC_CHECKIN", "LESSON_ONLY", "UNKNOWN"],
                requires: ["lessonId"],
                note: "静态码/课堂级签到，只要 lessonId"
            ),
            StrategySpec(
                id: "LESSON_WEB",
                endpoint: "checkinWeb",
                appliesTo: ["LESSON_ONLY", "UNKNOWN"],
                requires: ["lessonId"],
                note: "网页端兜底"
            ),
            StrategySpec(
                id: "QR_URL_POST",
                endpoint: nil,
                appliesTo: ["DYNAMIC_CHECKIN"],
                requires: ["c"],
                note: "仅允许同源或白名单域名直接把二维码 URL POST 一次"
            ),
            StrategySpec(
                id: "QR_URL_GET",
                endpoint: nil,
                appliesTo: ["DYNAMIC_CHECKIN"],
                requires: ["c"],
                note: "仅允许同源或白名单域名把二维码 URL 原样 GET"
            )
        ],
        qr: QrSpec(
            dynamicKeys: ["c", "t", "s"],
            lessonKeys: ["lessonId", "lesson_id", "lessonid", "lid"],
            classroomKeys: ["classroomId", "classroom_id", "classroomid", "cid"],
            checkinKeys: ["checkinId", "checkin_id", "signId", "sign_id"],
            loginPathHints: ["login", "qrcode", "scan", "qrconnect"],
            schemes: ["https", "http", "app", "yuketang", "ykt", "rainclassroom"],
            allowedUrlHosts: [
                "www.yuketang.cn",
                "pro.yuketang.cn",
                "changjiang.yuketang.cn",
                "huanghe.yuketang.cn",
                "www.xuetangx.com",
                "127.0.0.1:8787"
            ]
        ),
        result: ResultSpec(
            codeField: "code",
            altCodeKeys: ["errcode", "error_code", "status_code"],
            okCodes: [0],
            messageFields: ["msg", "message"],
            altMessageKeys: ["errmsg", "errormsg", "detail", "error"],
            alreadyKeywords: ["已签到", "已经签到", "重复签到", "已参与"],
            authKeywords: ["登录", "登陆", "未授权", "身份", "token", "会话", "unauthorized", "unauthenticated"],
            expiredKeywords: ["失效", "过期", "不存在", "二维码已", "dynamic qr check in refused", "qr code expired", "expired"],
            retryHttpStatus: [408, 425, 429, 500, 502, 503, 504]
        )
    )
}

/// 协议模板安全渲染器：支持 URL 路径段/查询参数编码与保留原始 JSON 类型的 Body 替换。
enum TemplateRenderer {
    private static let unreservedAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    static func renderString(_ text: String, variables: [String: TemplateValue]) -> String {
        replacePlaceholders(in: text) { key in
            guard let value = variables[key] else { return "" }
            return value.stringValue ?? ""
        }
    }

    static func renderPath(_ pathTemplate: String, variables: [String: TemplateValue]) -> String {
        replacePlaceholders(in: pathTemplate) { key in
            let raw = variables[key]?.stringValue ?? ""
            return encodeURLComponent(raw)
        }
    }

    static func renderQuery(_ query: [String: String], variables: [String: TemplateValue]) -> [String: String] {
        var rendered: [String: String] = [:]
        rendered.reserveCapacity(query.count)
        for (key, value) in query {
            rendered[key] = renderString(value, variables: variables)
        }
        return rendered
    }

    static func renderBody(
        _ body: [String: TemplateValue],
        variables: [String: TemplateValue]
    ) -> [String: TemplateValue] {
        var rendered: [String: TemplateValue] = [:]
        rendered.reserveCapacity(body.count)
        for (key, value) in body {
            rendered[key] = renderValue(value, variables: variables)
        }
        return rendered
    }

    static func renderValue(
        _ element: TemplateValue,
        variables: [String: TemplateValue]
    ) -> TemplateValue {
        switch element {
        case .object(let dict):
            return .object(renderBody(dict, variables: variables))
        case .array(let array):
            return .array(array.map { renderValue($0, variables: variables) })
        case .string(let raw):
            if let singleKey = exactPlaceholderKey(raw) {
                if let resolved = variables[singleKey], resolved != .null {
                    return resolved
                }
                return .string("")
            }
            return .string(renderString(raw, variables: variables))
        case .int, .double, .bool, .null:
            return element
        }
    }

    static func buildURL(base: String, path: String, query: [String: String]) -> String {
        var normalizedBase = base
        while normalizedBase.hasSuffix("/") {
            normalizedBase.removeLast()
        }

        let normalizedPath: String
        if path.isEmpty {
            normalizedPath = ""
        } else if path.hasPrefix("/") {
            normalizedPath = path
        } else {
            normalizedPath = "/\(path)"
        }

        let validPairs = query
            .filter {
                !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .sorted { $0.key < $1.key }

        if validPairs.isEmpty {
            return "\(normalizedBase)\(normalizedPath)"
        }

        let queryString = validPairs
            .map { "\(encodeURLComponent($0.key))=\(encodeURLComponent($0.value))" }
            .joined(separator: "&")

        let separator: String
        if !normalizedPath.contains("?") {
            separator = "?"
        } else if normalizedPath.hasSuffix("?") || normalizedPath.hasSuffix("&") {
            separator = ""
        } else {
            separator = "&"
        }

        return "\(normalizedBase)\(normalizedPath)\(separator)\(queryString)"
    }

    static func encodeURLComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreservedAllowed) ?? value
    }

    private static func exactPlaceholderKey(_ text: String) -> String? {
        guard text.hasPrefix("{"), text.hasSuffix("}"), text.count >= 3 else {
            return nil
        }
        let inner = text.dropFirst().dropLast()
        guard inner.allSatisfy(isPlaceholderKeyChar) else {
            return nil
        }
        return String(inner)
    }

    private static func replacePlaceholders(in text: String, resolver: (String) -> String) -> String {
        var output = ""
        output.reserveCapacity(text.count)
        var index = text.startIndex

        while index < text.endIndex {
            if text[index] == "{" {
                let keyStart = text.index(after: index)
                var cursor = keyStart
                while cursor < text.endIndex && isPlaceholderKeyChar(text[cursor]) {
                    cursor = text.index(after: cursor)
                }
                if cursor > keyStart && cursor < text.endIndex && text[cursor] == "}" {
                    let key = String(text[keyStart..<cursor])
                    output.append(resolver(key))
                    index = text.index(after: cursor)
                    continue
                }
            }
            output.append(text[index])
            index = text.index(after: index)
        }

        return output
    }

    private static func isPlaceholderKeyChar(_ ch: Character) -> Bool {
        ch.isASCII && (ch.isLetter || ch.isNumber || ch == "_")
    }
}
