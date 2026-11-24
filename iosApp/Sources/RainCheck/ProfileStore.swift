//
//  ProfileStore.swift
//  RainCheck
//
//  从 App bundle 读取 `protocol_profile.json`（逐字节同步自 `protocol/profile.json`），
//  提供模板渲染（含路径段安全编码）与完整可用的内置兜底配置（永不退回空配置）。
//

import Foundation

// MARK: - 模板渲染

enum Template {
    private static let pathAllowed: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return set
    }()

    static func render(_ text: String, vars: [String: JSONValue]) -> String {
        replacePlaceholders(in: text) { name in
            stringValue(vars[name])
        }
    }

    /// 渲染 URL path 模板，对动态路径段做 URL path 编码，防止 `/`, `?`, `#` 注入。
    static func renderPath(_ pathTemplate: String, vars: [String: JSONValue]) -> String {
        replacePlaceholders(in: pathTemplate) { name in
            let raw = vars[name]?.nonNullScalarString ?? ""
            return raw.addingPercentEncoding(withAllowedCharacters: pathAllowed) ?? raw
        }
    }

    static func renderMap(_ map: [String: String], vars: [String: JSONValue]) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in map {
            out[key] = render(value, vars: vars)
        }
        return out
    }

    static func renderBody(_ body: JSONValue, vars: [String: JSONValue]) -> JSONValue {
        renderElement(body, vars: vars)
    }

    static func renderElement(_ element: JSONValue, vars: [String: JSONValue]) -> JSONValue {
        switch element {
        case .object(let map):
            var out: [String: JSONValue] = [:]
            for (key, value) in map {
                out[key] = renderElement(value, vars: vars)
            }
            return .object(out)
        case .array(let items):
            return .array(items.map { renderElement($0, vars: vars) })
        case .string(let raw):
            if let name = singlePlaceholder(raw) {
                guard let value = vars[name], value != .null else {
                    return .string("")
                }
                return value
            }
            return .string(render(raw, vars: vars))
        case .int, .double, .bool, .null:
            return element
        }
    }

    static func singlePlaceholder(_ text: String) -> String? {
        guard text.count >= 3, text.hasPrefix("{"), text.hasSuffix("}") else {
            return nil
        }
        let inner = String(text.dropFirst().dropLast())
        return isValidName(inner) ? inner : nil
    }

    static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        for scalar in name.unicodeScalars {
            let value = scalar.value
            let isDigit = value >= 0x30 && value <= 0x39
            let isUpper = value >= 0x41 && value <= 0x5A
            let isLower = value >= 0x61 && value <= 0x7A
            let isUnderscore = value == 0x5F
            if !(isDigit || isUpper || isLower || isUnderscore) {
                return false
            }
        }
        return true
    }

    private static func replacePlaceholders(in text: String, transform: (String) -> String) -> String {
        var out = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "{" {
                if let close = text[index...].firstIndex(of: "}") {
                    let innerStart = text.index(after: index)
                    let inner = String(text[innerStart..<close])
                    if isValidName(inner) {
                        out += transform(inner)
                        index = text.index(after: close)
                        continue
                    }
                }
            }
            out.append(character)
            index = text.index(after: index)
        }
        return out
    }

    private static func stringValue(_ value: JSONValue?) -> String {
        guard let value, value != .null else { return "" }
        return value.stringValue
    }
}

// MARK: - ProfileStore

final class ProfileStore: Sendable {
    static let resourceName = "protocol_profile"
    static let resourceExtension = "json"

    let profile: ProtocolProfile
    let source: String
    let loadError: String?

    init(profile: ProtocolProfile, source: String, loadError: String? = nil) {
        self.profile = profile
        self.source = source
        self.loadError = loadError
    }

    /// 从指定 Bundle 读取协议 JSON；若资源缺失或损坏则使用完整内置兜底配置并暴露提示，绝不瘫痪。
    static func bundled(bundle: Bundle = .main) -> ProfileStore {
        guard let url = bundle.url(forResource: resourceName, withExtension: resourceExtension) else {
            return ProfileStore(
                profile: fallbackProfile(),
                source: "内置兜底配置",
                loadError: "未在 App 包中找到 \(resourceName).\(resourceExtension)，已自动启用内置完整兜底协议。"
            )
        }
        do {
            let data = try Data(contentsOf: url)
            let parsed = try ProtocolProfile.parse(data: data)
            return ProfileStore(profile: parsed, source: url.lastPathComponent, loadError: nil)
        } catch {
            return ProfileStore(
                profile: fallbackProfile(),
                source: "内置兜底配置",
                loadError: "解析 \(resourceName).\(resourceExtension) 失败（\(error.localizedDescription)），已回退内置完整协议。"
            )
        }
    }

    /// 完整内置兜底配置（与 `protocol/profile.json` 全部 7 站点 / 17 接口 / 6 策略 100% 对齐）。
    static func fallbackProfile() -> ProtocolProfile {
        ProtocolProfile(
            version: 1,
            name: "yuketang",
            updatedAt: "2026-11-24",
            defaultEdition: "www",
            editions: Edition.presets,
            headers: [
                "xtbz": "ykt",
                "desktop-v": "v2",
                "X-Client": "desktop",
                "Origin": "file://",
                "Accept": "application/json, text/plain, */*"
            ],
            userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36",
            auth: AuthSpec(),
            endpoints: [
                "me": EndpointSpec(method: "GET", path: "/api/v3/user/basic-info", auth: true),
                "loginPre": EndpointSpec(
                    method: "GET",
                    path: "/api/v3/user/login/pre-info",
                    auth: false,
                    note: "外部桌面端脚本推断，未经实网抓包验证"
                ),
                "loginWait": EndpointSpec(
                    method: "POST",
                    path: "/api/v3/user/login/wait-for-scan",
                    body: .object(["token": .string("{loginToken}")]),
                    auth: false,
                    note: "外部桌面端脚本推断，未经实网抓包验证"
                ),
                "loginPoll": EndpointSpec(
                    method: "POST",
                    path: "/api/v3/user/login",
                    body: .object(["token": .string("{loginToken}")]),
                    auth: false,
                    note: "外部桌面端脚本推断，未经实网抓包验证"
                ),
                "loginCode": EndpointSpec(
                    method: "POST",
                    path: "/api/v3/user/login/login-with-code",
                    body: .object(["token": .string("{loginToken}"), "code": .string("{code}")]),
                    auth: false,
                    note: "外部桌面端脚本推断，未经实网抓包验证"
                ),
                "activeLesson": EndpointSpec(
                    method: "GET",
                    path: "/api/v3/classroom/on-lesson-upcoming-exam",
                    auth: true
                ),
                "checkinList": EndpointSpec(
                    method: "POST",
                    path: "/api/v3/lesson/checkin-list",
                    body: .object(["lesson_id": .string("{lessonId}"), "page": .int(0), "limit": .int(20)]),
                    auth: true,
                    note: "IPA 实证属教师端 remote_control POST 接口（postSignList），非学生端 GET"
                ),
                "checkinDetail": EndpointSpec(
                    method: "POST",
                    path: "/api/v3/lesson/checkin/detail",
                    body: .object(["lesson_id": .string("{lessonId}"), "checkin_id": .string("{checkinId}")]),
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
                "checkinTicket": EndpointSpec(
                    method: "POST",
                    path: "/api/v3/lesson/checkin",
                    body: .object([
                        "lessonId": .string("{lessonId}"),
                        "source": .string("{source}"),
                        "ticket": .string("{c}"),
                        "t": .string("{t}"),
                        "s": .string("{s}")
                    ]),
                    auth: true,
                    note: "路径获 IPA 实证；source/ticket/t/s 请求体由外部桌面端脚本推断"
                ),
                "checkinDesktop": EndpointSpec(
                    method: "POST",
                    path: "/api/v3/lesson/checkin",
                    body: .object(["lessonId": .string("{lessonId}"), "source": .int(1)]),
                    auth: true
                ),
                "checkinWeb": EndpointSpec(
                    method: "POST",
                    path: "/api/lesson/web_check_in",
                    body: .object(["lessonId": .string("{lessonId}"), "source": .int(1)]),
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
                    body: .object(["lessonId": .string("{lessonId}")]),
                    auth: true,
                    note: "IPA 实证属教师端创建定位签到会话接口（非学生端流程）"
                ),
                "locationUpdateSession": EndpointSpec(
                    method: "POST",
                    path: "/api/v3/location-checkin/update-session",
                    body: .object(["lessonId": .string("{lessonId}")]),
                    auth: true,
                    note: "IPA 实证教师端更新定位签到会话接口（路径不含 /lesson/，非学生端流程）"
                ),
                "locationSubmit": EndpointSpec(
                    method: "POST",
                    path: "/api/v3/lesson/location-checkin/submit",
                    body: .object([
                        "lessonId": .string("{lessonId}"),
                        "latitude": .string("{latitude}"),
                        "longitude": .string("{longitude}"),
                        "accuracy": .string("{accuracy}")
                    ]),
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
            result: ResultSpec()
        )
    }

    // MARK: 查询与摘要

    func endpoint(_ name: String) -> EndpointSpec? {
        profile.endpoints[name]
    }

    func strategies(for kind: TicketKind) -> [StrategySpec] {
        profile.orderedStrategies(kind: kind)
    }

    var strategyChain: [String] {
        profile.strategies.map { $0.id }
    }

    var strategyChainText: String {
        let chain = strategyChain
        return chain.isEmpty ? "（profile 未声明策略）" : chain.joined(separator: " → ")
    }

    var editions: [Edition] {
        profile.editions.isEmpty ? Edition.presets : profile.editions
    }

    func edition(id: String) -> Edition? {
        editions.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }

    var defaultEdition: Edition {
        edition(id: profile.defaultEdition) ?? editions.first ?? Edition.WWW
    }

    var summary: String {
        "\(profile.name) v\(profile.version) · \(profile.strategies.count) 条策略 · \(profile.endpoints.count) 个接口"
    }
}
