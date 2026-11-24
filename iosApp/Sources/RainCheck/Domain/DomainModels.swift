import Foundation

/// 雨课堂校区 / 站点定义。`host` 不含 scheme，可包含显式端口号。
struct Edition: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let label: String
    let host: String
    let scheme: String

    init(id: String, label: String, host: String, scheme: String = "https") {
        self.id = id
        self.label = label
        self.host = host
        self.scheme = scheme
    }

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case host
        case scheme
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.label = try container.decode(String.self, forKey: .label)
        self.host = try container.decode(String.self, forKey: .host)
        let decodedScheme = try container.decodeIfPresent(String.self, forKey: .scheme)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.scheme = (decodedScheme?.isEmpty == false ? decodedScheme! : "https").lowercased()
    }

    var baseUrl: String {
        "\(scheme)://\(host)"
    }

    var shortLabel: String {
        switch id.lowercased() {
        case "www":
            return "雨课堂"
        case "pro":
            return "雨课堂 Pro"
        case "tsinghua":
            return "荷塘雨课堂"
        case "changjiang":
            return "长江雨课堂"
        case "huanghe":
            return "黄河雨课堂"
        case "xuetangx":
            return "学堂在线"
        case "mock":
            return "本地演练"
        default:
            if let parenIndex = label.firstIndex(of: "（") {
                let prefix = String(label[..<parenIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !prefix.isEmpty {
                    return prefix
                }
            }
            return label
        }
    }

    static let www = Edition(id: "www", label: "雨课堂", host: "www.yuketang.cn", scheme: "https")
    static let pro = Edition(id: "pro", label: "雨课堂 Pro（荷塘/专业版）", host: "pro.yuketang.cn", scheme: "https")
    static let tsinghua = Edition(id: "tsinghua", label: "荷塘雨课堂", host: "pro.yuketang.cn", scheme: "https")
    static let changjiang = Edition(id: "changjiang", label: "长江雨课堂", host: "changjiang.yuketang.cn", scheme: "https")
    static let huanghe = Edition(id: "huanghe", label: "黄河雨课堂", host: "huanghe.yuketang.cn", scheme: "https")
    static let xuetangx = Edition(id: "xuetangx", label: "学堂在线", host: "www.xuetangx.com", scheme: "https")
    static let mock = Edition(id: "mock", label: "本地演练环境", host: "127.0.0.1:8787", scheme: "http")

    static let presets: [Edition] = [
        www,
        pro,
        tsinghua,
        changjiang,
        huanghe,
        xuetangx,
        mock
    ]

    static func fromHost(_ host: String, scheme: String? = nil) -> Edition {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedScheme = scheme?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let effectiveScheme = (normalizedScheme?.isEmpty == false) ? normalizedScheme : nil

        if let matched = presets.first(where: { $0.host.caseInsensitiveCompare(normalizedHost) == .orderedSame }) {
            if let effectiveScheme, effectiveScheme.caseInsensitiveCompare(matched.scheme) != .orderedSame {
                return Edition(
                    id: matched.id,
                    label: matched.label,
                    host: matched.host,
                    scheme: effectiveScheme
                )
            }
            return matched
        }

        return Edition(
            id: normalizedHost,
            label: normalizedHost,
            host: normalizedHost,
            scheme: effectiveScheme ?? "https"
        )
    }
}

/// 签到账号模型，支持 Bearer Token 与 Cookie（sessionid + csrftoken）双载体。
struct Account: Codable, Hashable, Identifiable, Sendable {
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
        id: String = UUID().uuidString,
        label: String,
        host: String = "www.yuketang.cn",
        scheme: String = "https",
        bearer: String? = nil,
        sessionId: String? = nil,
        csrfToken: String? = nil,
        enabled: Bool = true,
        createdAt: Int64 = RainCheckTime.nowMillis(),
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

    var edition: Edition {
        Edition.fromHost(host, scheme: scheme)
    }

    var hasCredential: Bool {
        let hasBearer = !(bearer?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasSession = !(sessionId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        return hasBearer || hasSession
    }

    var authKindLabel: String {
        let hasBearer = !(bearer?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasSession = !(sessionId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        switch (hasBearer, hasSession) {
        case (true, true):
            return "Bearer + Cookie"
        case (true, false):
            return "Bearer Token"
        case (false, true):
            return "Cookie 会话"
        case (false, false):
            return "未配置"
        }
    }

    /// 判断标签是否为空或自动生成的占位名（校验通过时可安全升级为服务端真实用户名）。
    static func isPlaceholderLabel(_ label: String) -> Bool {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            || trimmed.hasPrefix("雨课堂用户(")
            || trimmed.hasPrefix("账号 ")
    }

    /// 脱敏展示凭据，与 Kotlin `Models.kt` 规则保持严格一致。
    func maskedCredential() -> String {
        let raw: String
        if let token = bearer, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            raw = token
        } else if let sid = sessionId, !sid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            raw = sid
        } else {
            return "未配置"
        }

        let length = raw.count
        if length <= 12 {
            return "****"
        } else if length <= 20 {
            return "\(raw.prefix(2))…\(raw.suffix(2))"
        } else {
            return "\(raw.prefix(4))…\(raw.suffix(3))"
        }
    }
}

/// 二维码业务分类。
enum TicketKind: String, Codable, Hashable, Sendable {
    case dynamicCheckin = "DYNAMIC_CHECKIN"
    case lessonOnly = "LESSON_ONLY"
    case login = "LOGIN"
    case unknown = "UNKNOWN"

    var displayTitle: String {
        switch self {
        case .dynamicCheckin:
            return "动态签到码"
        case .lessonOnly:
            return "课堂签到"
        case .login:
            return "登录二维码"
        case .unknown:
            return "未识别内容"
        }
    }
}

/// 解析后的二维码票据。
struct QrTicket: Codable, Hashable, Sendable {
    let raw: String
    let kind: TicketKind
    let url: String?
    let host: String?
    let params: [String: String]
    let lessonId: String?
    let classroomId: String?
    let checkinId: String?

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

    /// 解析动态码时间戳 `t`（自动兼容 10 位秒级与 13 位毫秒级时间戳）。
    var issuedAtEpochSeconds: TimeInterval? {
        guard let rawTimestamp = timestamp?.trimmingCharacters(in: .whitespacesAndNewlines),
              let numeric = Double(rawTimestamp),
              numeric.isFinite,
              numeric > 0 else {
            return nil
        }
        return numeric > 10_000_000_000 ? numeric / 1000.0 : numeric
    }

    func summary() -> String {
        switch kind {
        case .dynamicCheckin:
            let codePrefix = String((dynamicCode ?? "").prefix(8))
            return "动态码 c=\(codePrefix)… t=\(timestamp ?? "")"
        case .lessonOnly:
            return "课堂 lessonId=\(lessonId ?? "?")"
        case .login:
            return "登录二维码"
        case .unknown:
            return "未识别: \(String(raw.prefix(40)))"
        }
    }
}

/// 单账号签到执行状态。
enum SignState: String, Codable, Hashable, Sendable {
    case success = "SUCCESS"
    case already = "ALREADY"
    case authExpired = "AUTH_EXPIRED"
    case qrExpired = "QR_EXPIRED"
    case notInClass = "NOT_IN_CLASS"
    case networkError = "NETWORK_ERROR"
    case failed = "FAILED"
    case dryRun = "DRY_RUN"

    var displayTitle: String {
        switch self {
        case .success:
            return "签到成功"
        case .already:
            return "已签到"
        case .authExpired:
            return "登录过期"
        case .qrExpired:
            return "二维码失效"
        case .notInClass:
            return "未在课堂中"
        case .networkError:
            return "网络异常"
        case .failed:
            return "签到失败"
        case .dryRun:
            return "模拟演练"
        }
    }

    var symbolName: String {
        switch self {
        case .success:
            return "checkmark.circle.fill"
        case .already:
            return "checkmark.circle"
        case .authExpired:
            return "person.crop.circle.badge.exclamationmark"
        case .qrExpired:
            return "clock.badge.exclamationmark"
        case .notInClass:
            return "questionmark.circle"
        case .networkError:
            return "wifi.exclamationmark"
        case .failed:
            return "xmark.circle"
        case .dryRun:
            return "testtube.2"
        }
    }

    var isSuccessLike: Bool {
        self == .success || self == .already
    }

    var isDryRun: Bool {
        self == .dryRun
    }

    var isFailureLike: Bool {
        !isSuccessLike && self != .dryRun
    }
}

/// 单次策略尝试轨迹（不含任何敏感请求头/凭据）。
struct AttemptTrace: Codable, Hashable, Sendable, Identifiable {
    let strategyId: String
    let method: String
    let url: String
    let httpStatus: Int?
    let businessCode: Int?
    let message: String
    let elapsedMs: Int64

    init(
        strategyId: String,
        method: String,
        url: String,
        httpStatus: Int? = nil,
        businessCode: Int? = nil,
        message: String,
        elapsedMs: Int64 = 0
    ) {
        self.strategyId = strategyId
        self.method = method
        self.url = url
        self.httpStatus = httpStatus
        self.businessCode = businessCode
        self.message = message
        self.elapsedMs = elapsedMs
    }

    var id: String {
        "\(strategyId)|\(method)|\(url)|\(httpStatus.map(String.init) ?? "none")|\(businessCode.map(String.init) ?? "none")|\(elapsedMs)|\(message.prefix(32))"
    }
}

/// 单账号签到结果。
/// `CodingKeys` 显式排除 `refreshedAccount` 及任何凭据字段，确保导出报告零明文泄漏。
struct SignResult: Codable, Hashable, Sendable, Identifiable {
    let accountId: String
    let accountLabel: String
    let host: String
    let state: SignState
    let strategyId: String?
    let httpStatus: Int?
    let message: String
    let elapsedMs: Int64
    let attempts: [AttemptTrace]
    let timestampMs: Int64
    let refreshedAccount: Account?

    var id: String {
        "\(accountId)-\(timestampMs)"
    }

    enum CodingKeys: String, CodingKey {
        case accountId
        case accountLabel
        case host
        case state
        case strategyId
        case httpStatus
        case message
        case elapsedMs
        case attempts
        case timestampMs
    }

    init(
        accountId: String,
        accountLabel: String,
        host: String,
        state: SignState,
        strategyId: String? = nil,
        httpStatus: Int? = nil,
        message: String,
        elapsedMs: Int64 = 0,
        attempts: [AttemptTrace] = [],
        timestampMs: Int64 = RainCheckTime.nowMillis(),
        refreshedAccount: Account? = nil
    ) {
        self.accountId = accountId
        self.accountLabel = accountLabel
        self.host = host
        self.state = state
        self.strategyId = strategyId
        self.httpStatus = httpStatus
        self.message = message
        self.elapsedMs = elapsedMs
        self.attempts = attempts
        self.timestampMs = timestampMs
        self.refreshedAccount = refreshedAccount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.accountId = try container.decode(String.self, forKey: .accountId)
        self.accountLabel = try container.decode(String.self, forKey: .accountLabel)
        self.host = try container.decode(String.self, forKey: .host)
        self.state = try container.decode(SignState.self, forKey: .state)
        self.strategyId = try container.decodeIfPresent(String.self, forKey: .strategyId)
        self.httpStatus = try container.decodeIfPresent(Int.self, forKey: .httpStatus)
        self.message = try container.decode(String.self, forKey: .message)
        self.elapsedMs = try container.decode(Int64.self, forKey: .elapsedMs)
        self.attempts = try container.decodeIfPresent([AttemptTrace].self, forKey: .attempts) ?? []
        self.timestampMs = try container.decode(Int64.self, forKey: .timestampMs)
        self.refreshedAccount = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accountId, forKey: .accountId)
        try container.encode(accountLabel, forKey: .accountLabel)
        try container.encode(host, forKey: .host)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(strategyId, forKey: .strategyId)
        try container.encodeIfPresent(httpStatus, forKey: .httpStatus)
        try container.encode(message, forKey: .message)
        try container.encode(elapsedMs, forKey: .elapsedMs)
        try container.encode(attempts, forKey: .attempts)
        try container.encode(timestampMs, forKey: .timestampMs)
    }
}

/// 脱敏签到报告导出载体。
struct ExportReport: Codable, Sendable {
    let exportedAt: String
    let ticketSummary: String?
    let dryRun: Bool
    let results: [SignResult]

    init(
        exportedAt: String,
        ticketSummary: String?,
        dryRun: Bool,
        results: [SignResult]
    ) {
        self.exportedAt = exportedAt
        self.ticketSummary = ticketSummary
        self.dryRun = dryRun
        self.results = results
    }
}

/// 凭据与站点输入的智能清洗工具（支持直接粘贴完整请求头、Cookie 串或完整 URL）。
enum CredentialSanitizer {
    private static let quoteAndSpaceSet = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "\"'`"))

    static func cleanBearer(_ raw: String) -> String? {
        var working = raw
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: quoteAndSpaceSet)
        if working.isEmpty {
            return nil
        }

        let headerPrefixes = ["authorization:", "set-auth:"]
        for prefix in headerPrefixes {
            if working.lowercased().hasPrefix(prefix) {
                working = String(working.dropFirst(prefix.count))
                    .trimmingCharacters(in: quoteAndSpaceSet)
            }
        }

        while working.lowercased().hasPrefix("bearer ") {
            working = String(working.dropFirst("bearer ".count))
                .trimmingCharacters(in: quoteAndSpaceSet)
        }

        if working.lowercased() == "bearer" {
            return nil
        }

        working = working.trimmingCharacters(in: quoteAndSpaceSet)
        return working.isEmpty ? nil : working
    }

    private static let cookieAttributeNames: Set<String> = [
        "path", "domain", "expires", "max-age", "samesite", "httponly", "secure", "priority", "partitioned"
    ]

    /// 将逗号拼接的多条 `Set-Cookie` 响应头按真实 Cookie 边界拆分：
    /// 仅在引号外遇到 `,` 且其后紧跟非属性名的 `<cookie-name>=` 时切分，
    /// 绝不破坏 `expires=Tue, 23-Nov-2027 11:52:14 GMT` 等日期中的逗号。
    static func splitSetCookieHeader(_ raw: String) -> [String] {
        let chars = Array(raw)
        let count = chars.count
        var entries: [String] = []
        var segmentStart = 0
        var inQuotes = false
        var index = 0

        while index < count {
            let ch = chars[index]
            if ch == "\"" {
                inQuotes.toggle()
                index += 1
                continue
            }
            if ch == "," && !inQuotes && isCookieBoundary(chars: chars, afterCommaIndex: index + 1) {
                let piece = String(chars[segmentStart..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty {
                    entries.append(piece)
                }
                segmentStart = index + 1
            }
            index += 1
        }

        if segmentStart <= count {
            let tail = String(chars[segmentStart..<count]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty {
                entries.append(tail)
            }
        }
        return entries
    }

    private static func isCookieBoundary(chars: [Character], afterCommaIndex: Int) -> Bool {
        var cursor = afterCommaIndex
        let count = chars.count
        while cursor < count && (chars[cursor] == " " || chars[cursor] == "\t") {
            cursor += 1
        }
        let tokenStart = cursor
        while cursor < count {
            let ch = chars[cursor]
            if ch == "=" {
                guard cursor > tokenStart else { return false }
                let token = String(chars[tokenStart..<cursor]).lowercased()
                return !cookieAttributeNames.contains(token)
            }
            if !isCookieNameChar(ch) {
                return false
            }
            cursor += 1
        }
        return false
    }

    private static func isCookieNameChar(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else {
            return false
        }
        let value = scalar.value
        if value <= 0x20 || value >= 0x7F {
            return false
        }
        switch ch {
        case "(", ")", "<", ">", "@", ",", ";", ":", "\\", "\"", "/", "[", "]", "?", "=", "{", "}":
            return false
        default:
            return true
        }
    }

    private static func isExpiredCookieEntry(segments: [String]) -> Bool {
        for segment in segments.dropFirst() {
            guard let eqIdx = segment.firstIndex(of: "=") else { continue }
            let attrName = String(segment[..<eqIdx]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let attrVal = String(segment[segment.index(after: eqIdx)...]).trimmingCharacters(in: quoteAndSpaceSet)
            if attrName == "max-age", let seconds = Int(attrVal), seconds <= 0 {
                return true
            }
            if attrName == "expires", (attrVal.contains("1970") || attrVal.contains("1969")) {
                return true
            }
        }
        return false
    }

    /// 从原始 Cookie 字符串、`Cookie:` / `Set-Cookie:` 响应头或单个值中提取目标 Cookie。
    /// - Parameters:
    ///   - raw: 原始输入或 `Set-Cookie` 头文本。
    ///   - key: 目标 Cookie 名称（如 `"sessionid"`、`"csrftoken"`）。
    ///   - allowBareValue: 是否允许无 `=` 的纯单值回退；解析 HTTP `Set-Cookie` 或跨字段提取 `csrftoken` 时
    ///     必须传 `false`，仅直接单字段手工输入允许传 `true`。任何不匹配的 `other=val` 键值对均绝不返回。
    static func cleanCookieValue(_ raw: String, key: String, allowBareValue: Bool = true) -> String? {
        let normalizedNewlines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedNewlines.isEmpty {
            return nil
        }

        var hadCookieHeaderPrefix = false
        var cookieEntries: [String] = []
        for rawLine in normalizedNewlines.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            for prefix in ["set-cookie:", "cookie:"] {
                if line.lowercased().hasPrefix(prefix) {
                    hadCookieHeaderPrefix = true
                    line = String(line.dropFirst(prefix.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            if !line.isEmpty {
                cookieEntries.append(contentsOf: splitSetCookieHeader(line))
            }
        }
        if cookieEntries.isEmpty {
            return nil
        }

        let targetKeys: [String]
        if key.caseInsensitiveCompare("sessionid") == .orderedSame {
            targetKeys = [key.lowercased(), "sid"]
        } else {
            targetKeys = [key.lowercased()]
        }

        let entrySegments: [[String]] = cookieEntries.map { entry in
            entry
                .split(separator: ";", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        for candidateKey in targetKeys {
            for segments in entrySegments {
                if isExpiredCookieEntry(segments: segments) {
                    continue
                }
                for segment in segments {
                    guard let eqIdx = segment.firstIndex(of: "=") else { continue }
                    let name = String(segment[..<eqIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let lowerName = name.lowercased()
                    if cookieAttributeNames.contains(lowerName) {
                        continue
                    }
                    if lowerName == candidateKey {
                        let value = String(segment[segment.index(after: eqIdx)...])
                            .trimmingCharacters(in: quoteAndSpaceSet)
                        if value.isEmpty || value.caseInsensitiveCompare("deleted") == .orderedSame {
                            continue
                        }
                        return value
                    }
                }
            }
        }

        guard allowBareValue else {
            return nil
        }

        let allSegments = entrySegments.flatMap { $0 }
        guard !hadCookieHeaderPrefix,
              cookieEntries.count == 1,
              allSegments.count == 1,
              let only = allSegments.first,
              !only.contains("=") else {
            return nil
        }

        let cleaned = only.trimmingCharacters(in: quoteAndSpaceSet)
        if cleaned.isEmpty
            || cleaned.caseInsensitiveCompare("deleted") == .orderedSame
            || cookieAttributeNames.contains(cleaned.lowercased()) {
            return nil
        }
        return cleaned
    }

    static func cleanHost(_ raw: String) -> (host: String, scheme: String?) {
        let trimmed = raw.trimmingCharacters(in: quoteAndSpaceSet)
        if trimmed.isEmpty {
            return ("", nil)
        }

        var detectedScheme: String?
        var remainder = trimmed

        if let schemeRange = trimmed.range(of: "://") {
            let candidateScheme = String(trimmed[..<schemeRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if !candidateScheme.isEmpty,
               candidateScheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == ".") }) {
                detectedScheme = candidateScheme
            }
            remainder = String(trimmed[schemeRange.upperBound...])
        }

        if let cutIdx = remainder.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            remainder = String(remainder[..<cutIdx])
        }
        if let atIdx = remainder.lastIndex(of: "@") {
            remainder = String(remainder[remainder.index(after: atIdx)...])
        }

        let cleanedHost = remainder
            .trimmingCharacters(in: quoteAndSpaceSet)
            .lowercased()
        return (cleanedHost, detectedScheme)
    }
}

enum RainCheckTime {
    static func nowMillis() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000.0).rounded())
    }
}
