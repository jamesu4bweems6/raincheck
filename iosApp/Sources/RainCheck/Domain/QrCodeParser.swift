import Foundation

/// 二维码解析器与同源安全护栏（与 Kotlin `QrParser.kt` 及 `Profile.kt` 100% 对齐）。
enum QrCodeParser {
    private static let outerTrimSet = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "\"'"))

    static func parse(_ rawInput: String, profile: ProtocolProfile = ProtocolCatalog.loadBundled()) -> QrTicket {
        let raw = rawInput.trimmingCharacters(in: outerTrimSet)
        if raw.isEmpty {
            return QrTicket(raw: raw, kind: .unknown)
        }

        // 先剥离 URL #fragment，防止污染最后一个 query 参数值
        let clean = substringBefore(raw, marker: "#").trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty {
            return QrTicket(raw: raw, kind: .unknown)
        }

        let spec = profile.qr
        let url = resolveUrl(clean, spec: spec, profile: profile)

        // 若显式包含 "://" 但协议不在白名单 schemes 中，按非法/不支持输入返回 UNKNOWN
        if url == nil && clean.contains("://") {
            return QrTicket(raw: raw, kind: .unknown)
        }

        let query: [String: String]
        if let resolved = url {
            if let qMark = resolved.firstIndex(of: "?") {
                query = parseQuery(String(resolved[resolved.index(after: qMark)...]))
            } else {
                query = [:]
            }
        } else if clean.contains("=") {
            var trimmedQuery = clean
            while trimmedQuery.hasPrefix("?") || trimmedQuery.hasPrefix("&") {
                trimmedQuery.removeFirst()
            }
            query = parseQuery(trimmedQuery)
        } else {
            query = [:]
        }

        let host = url.flatMap { extractHost($0) }
        let path = url.map { extractPath($0) } ?? ""

        let lessonId = firstNonBlank(in: query, keys: spec.lessonKeys)
        let classroomId = firstNonBlank(in: query, keys: spec.classroomKeys)
        let checkinId = firstNonBlank(in: query, keys: spec.checkinKeys)

        let dynamicKeys = spec.dynamicKeys.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let hasDynamic = !dynamicKeys.isEmpty && dynamicKeys.allSatisfy { key in
            guard let val = query[key] else { return false }
            return !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        // 明确登录信号（仅匹配 path 或特定参数，绝不误匹配 host）
        let lowerPath = path.lowercased()
        let isExplicitLogin = lowerPath.contains("qrconnect")
            || lowerPath.contains("login")
            || lowerPath.contains("scan-handler")
            || query["qrContent"] != nil

        // 宽泛登录路径提示（优先级低于显式 lessonId / classroomId）
        let isBroadLoginPath = spec.loginPathHints.contains { hint in
            let trimmed = hint.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && lowerPath.contains(trimmed.lowercased())
        }

        let isPureDigits = !clean.isEmpty && clean.allSatisfy { $0.isASCII && $0.isNumber }

        let kind: TicketKind
        if hasDynamic {
            kind = .dynamicCheckin
        } else if isExplicitLogin {
            kind = .login
        } else if lessonId != nil || classroomId != nil || isPureDigits {
            kind = .lessonOnly
        } else if isBroadLoginPath {
            kind = .login
        } else {
            kind = .unknown
        }

        let resolvedLesson = lessonId ?? ((kind == .lessonOnly && isPureDigits) ? clean : nil)

        return QrTicket(
            raw: raw,
            kind: kind,
            url: url,
            host: host,
            params: query,
            lessonId: resolvedLesson,
            classroomId: classroomId,
            checkinId: checkinId
        )
    }

    /// 校验二维码中的直接请求 URL 是否属于同源或白名单域名与安全协议。
    static func validateQrUrl(_ urlString: String, accountHost: String, profile: ProtocolProfile) -> Bool {
        let cleaned = CredentialSanitizer.cleanHost(accountHost)
        let effectiveHost = cleaned.host
        let effectiveScheme = cleaned.scheme
            ?? profile.editionForHost(effectiveHost)?.scheme
            ?? "https"
        return qrUrlValidationError(
            urlString,
            accountHost: effectiveHost.isEmpty ? nil : effectiveHost,
            accountScheme: effectiveHost.isEmpty ? nil : effectiveScheme,
            profile: profile
        ) == nil
    }

    static func validateQrUrl(_ urlString: String, account: Account?, profile: ProtocolProfile) -> Bool {
        qrUrlValidationError(
            urlString,
            accountHost: account?.host,
            accountScheme: account?.scheme,
            profile: profile
        ) == nil
    }

    /// 返回 `nil` 表示放行；非空字符串为拦截原因。
    static func qrUrlValidationError(
        _ urlString: String,
        accountHost: String?,
        accountScheme: String?,
        profile: ProtocolProfile
    ) -> String? {
        guard let scheme = extractScheme(urlString)?.lowercased() else {
            return "URL 缺少合法协议"
        }
        guard scheme == "https" || scheme == "http" else {
            return "不允许的协议: \(scheme)"
        }

        guard let schemeRange = urlString.range(of: "://") else {
            return "URL 缺少合法协议"
        }
        let afterScheme = String(urlString[schemeRange.upperBound...])
        let authority = extractAuthority(fromAfterScheme: afterScheme)
        if authority.isEmpty {
            return "URL 缺少主机名"
        }
        if authority.contains("@") || authority.contains("\\") || authority.contains(where: { $0.isWhitespace }) {
            return "URL 主机段包含不安全字符"
        }

        guard let hostPort = extractHost(urlString) else {
            return "无法解析 URL 主机名"
        }
        let normalized = normalizeHostPort(scheme: scheme, rawHost: hostPort)

        var allowedHttps = Set<String>()
        var allowedHttp = Set<String>()

        for edition in profile.editions {
            let edScheme = edition.scheme.lowercased()
            if edScheme == "https" {
                allowedHttps.insert(normalizeHostPort(scheme: "https", rawHost: edition.host))
            } else if edScheme == "http" {
                allowedHttp.insert(normalizeHostPort(scheme: "http", rawHost: edition.host))
            }
        }
        for allowedHost in profile.qr.allowedUrlHosts {
            let trimmed = allowedHost.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                allowedHttps.insert(normalizeHostPort(scheme: "https", rawHost: trimmed))
            }
        }
        if let accountHost {
            let trimmedHost = accountHost.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedHost.isEmpty {
                let accScheme = (accountScheme ?? "https").lowercased()
                if accScheme == "https" {
                    allowedHttps.insert(normalizeHostPort(scheme: "https", rawHost: trimmedHost))
                } else if accScheme == "http" {
                    allowedHttp.insert(normalizeHostPort(scheme: "http", rawHost: trimmedHost))
                }
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

    static func isHostAllowlisted(_ host: String?, profile: ProtocolProfile) -> Bool {
        guard let host else { return false }
        let cleaned = CredentialSanitizer.cleanHost(host).host
        if cleaned.isEmpty {
            return false
        }
        let normalizedHttps = normalizeHostPort(scheme: "https", rawHost: cleaned)
        let normalizedHttp = normalizeHostPort(scheme: "http", rawHost: cleaned)

        for allowed in profile.qr.allowedUrlHosts {
            let trimmed = allowed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if trimmed.isEmpty { continue }
            if trimmed == cleaned
                || normalizeHostPort(scheme: "https", rawHost: trimmed) == normalizedHttps
                || normalizeHostPort(scheme: "http", rawHost: trimmed) == normalizedHttp {
                return true
            }
        }

        for edition in profile.editions {
            let edHost = edition.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if edHost.isEmpty { continue }
            let edNorm = normalizeHostPort(scheme: edition.scheme.lowercased(), rawHost: edHost)
            if edHost == cleaned || edNorm == normalizedHttps || edNorm == normalizedHttp {
                return true
            }
        }

        return false
    }

    // MARK: - Query & URL Parsing Internals

    static func parseQuery(_ query: String) -> [String: String] {
        let cleaned = substringBefore(query, marker: "#")
        if cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [:]
        }

        var output: [String: String] = [:]
        for rawPair in cleaned.split(separator: "&", omittingEmptySubsequences: false) {
            let pair = String(rawPair)
            if pair.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }
            let key: String
            let value: String
            if let eqIdx = pair.firstIndex(of: "=") {
                key = String(pair[..<eqIdx])
                value = String(pair[pair.index(after: eqIdx)...])
            } else {
                key = pair
                value = ""
            }
            let decodedKey = decodeFormUTF8(key)
            if !decodedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               output[decodedKey] == nil {
                output[decodedKey] = decodeFormUTF8(value)
            }
        }
        return output
    }

    /// UTF-8 安全 URL 解码：`+` 转空格，`%XX` 字节拼接，正确保留多字节中文与字面量 Unicode。
    static func decodeFormUTF8(_ value: String) -> String {
        if !value.contains("%") && !value.contains("+") {
            return value
        }

        let scalars = Array(value.utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(scalars.count)

        var i = 0
        while i < scalars.count {
            let b = scalars[i]
            if b == 0x2B { // '+'
                bytes.append(0x20) // ' '
                i += 1
            } else if b == 0x25, i + 2 < scalars.count,
                      let hi = hexNibble(scalars[i + 1]),
                      let lo = hexNibble(scalars[i + 2]) {
                bytes.append((hi << 4) | lo)
                i += 3
            } else {
                bytes.append(b)
                i += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func extractScheme(_ url: String) -> String? {
        guard let range = url.range(of: "://"), range.lowerBound > url.startIndex else {
            return nil
        }
        let scheme = String(url[..<range.lowerBound])
        guard scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == ".") }) else {
            return nil
        }
        return scheme.lowercased()
    }

    static func extractHost(_ url: String) -> String? {
        guard let range = url.range(of: "://") else { return nil }
        let afterScheme = String(url[range.upperBound...])
        if afterScheme.isEmpty { return nil }

        let authority = extractAuthority(fromAfterScheme: afterScheme)
        let hostPort: String
        if let atIdx = authority.firstIndex(of: "@") {
            hostPort = String(authority[authority.index(after: atIdx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            hostPort = authority.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if hostPort.isEmpty { return nil }

        if hostPort.hasPrefix("[") {
            guard let closeIdx = hostPort.firstIndex(of: "]"),
                  closeIdx > hostPort.index(after: hostPort.startIndex) else {
                return nil
            }
            let rest = String(hostPort[hostPort.index(after: closeIdx)...])
            if !rest.isEmpty {
                guard rest.hasPrefix(":"),
                      let port = Int(rest.dropFirst()),
                      (1...65535).contains(port) else {
                    return nil
                }
            }
            return hostPort.lowercased()
        }

        if let colonIdx = hostPort.firstIndex(of: ":") {
            let hostPart = String(hostPort[..<colonIdx])
            let portPart = String(hostPort[hostPort.index(after: colonIdx)...])
            guard !hostPart.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let port = Int(portPart),
                  (1...65535).contains(port) else {
                return nil
            }
            return "\(hostPart.lowercased()):\(port)"
        }

        return hostPort.lowercased()
    }

    static func extractPath(_ url: String) -> String {
        guard let range = url.range(of: "://") else { return "" }
        let afterScheme = String(url[range.upperBound...])
        if afterScheme.isEmpty { return "" }

        let beforeQueryOrFrag = substringBefore(substringBefore(afterScheme, marker: "#"), marker: "?")
        guard let slashIdx = beforeQueryOrFrag.firstIndex(of: "/") else {
            return "/"
        }
        return String(beforeQueryOrFrag[slashIdx...])
    }

    private static func resolveUrl(_ clean: String, spec: QrSpec, profile: ProtocolProfile) -> String? {
        if let range = clean.range(of: "://"), range.lowerBound > clean.startIndex {
            let scheme = String(clean[..<range.lowerBound])
            let allowed = spec.schemes.contains { $0.caseInsensitiveCompare(scheme) == .orderedSame }
            return allowed ? clean : nil
        }

        let sepIdx = clean.firstIndex(where: { $0 == "/" || $0 == "?" })
        let head = sepIdx.map { String(clean[..<$0]) } ?? clean
        if head.isEmpty || head.contains(where: { $0 == "=" || $0 == "&" || $0.isWhitespace }) {
            return nil
        }

        let hasPathOrQuery = sepIdx != nil
        let looksLikeDomain = head.contains(".") && !head.hasPrefix(".") && !head.hasSuffix(".")
        let lowerHead = head.lowercased()
        let looksLikeLocalhost = lowerHead == "localhost" || lowerHead.hasPrefix("localhost:")
        let looksLikeIpv6 = head.hasPrefix("[") && head.contains("]")
        let knownHost = profile.editionForHost(head) != nil
            || spec.allowedUrlHosts.contains { $0.caseInsensitiveCompare(head) == .orderedSame }

        if (hasPathOrQuery && (looksLikeDomain || looksLikeLocalhost || looksLikeIpv6)) || knownHost {
            let inferredScheme = profile.editionForHost(head)?.scheme ?? "https"
            return "\(inferredScheme)://\(clean)"
        }

        return nil
    }

    private static func normalizeHostPort(scheme: String, rawHost: String) -> String {
        let lower = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if scheme == "https" && lower.hasSuffix(":443") {
            return String(lower.dropLast(4))
        }
        if scheme == "http" && lower.hasSuffix(":80") {
            return String(lower.dropLast(3))
        }
        return lower
    }

    private static func extractAuthority(fromAfterScheme afterScheme: String) -> String {
        if let cutIdx = afterScheme.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            return String(afterScheme[..<cutIdx])
        }
        return afterScheme
    }

    private static func firstNonBlank(in query: [String: String], keys: [String]) -> String? {
        for key in keys {
            if let val = query[key], !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return val
            }
        }
        return nil
    }

    private static func substringBefore(_ text: String, marker: Character) -> String {
        guard let idx = text.firstIndex(of: marker) else { return text }
        return String(text[..<idx])
    }

    private static func hexNibble(_ ascii: UInt8) -> UInt8? {
        switch ascii {
        case 0x30...0x39: // '0'...'9'
            return ascii - 0x30
        case 0x41...0x46: // 'A'...'F'
            return ascii - 0x41 + 10
        case 0x61...0x66: // 'a'...'f'
            return ascii - 0x61 + 10
        default:
            return nil
        }
    }
}
