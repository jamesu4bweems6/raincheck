//
//  QrParser.swift
//  RainCheck
//
//  二维码解析器，与 `core/src/commonMain/kotlin/cn/raincheck/core/QrParser.kt` 100% 行为对齐：
//   - 剥离 `#fragment`，避免污染最后一个 query 参数；
//   - 支持完整 URL（含 `https`/`http`/`app://yuketang`、显式端口、IPv6）与无 scheme 链接；
//   - 显式非法 scheme（如 `ftp://`）返回 `UNKNOWN`；
//   - `trimLeading` 只裁剪开头 `?`/`&`，绝不破坏末尾 `?` 签名；
//   - 严格使用 `profile.qr.dynamicKeys`；
//   - `loginPathHints` 仅匹配 `path`，且显式 `lessonId`/`classroomId` 优先级高于宽泛提示。
//

import Foundation

enum QrParser {
    static func parse(_ rawInput: String, profile: ProtocolProfile = ProtocolProfile()) -> QrTicket {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        if raw.isEmpty {
            return QrTicket(raw: raw, kind: .UNKNOWN)
        }

        // 先剥离 URL #fragment，防止污染最后一个 query 参数值
        let clean = substringBefore(raw, separator: "#").trimmed
        if clean.isEmpty {
            return QrTicket(raw: raw, kind: .UNKNOWN)
        }

        let spec = profile.qr
        let url = resolveUrl(clean, spec: spec, profile: profile)

        // 若显式包含 "://" 但协议不在白名单 schemes 中，按不支持输入返回 UNKNOWN
        if url == nil && clean.contains("://") {
            return QrTicket(raw: raw, kind: .UNKNOWN)
        }

        let query: [String: String]
        if let url {
            query = queryOf(substringAfter(url, separator: "?"))
        } else if clean.contains("=") {
            query = queryOf(trimLeading(clean, characters: "?&"))
        } else {
            query = [:]
        }

        let host = url.flatMap { extractHost($0) }
        let path = url.map { extractPath($0) } ?? ""

        let lessonId = firstValue(in: query, keys: spec.lessonKeys)
        let classroomId = firstValue(in: query, keys: spec.classroomKeys)
        let checkinId = firstValue(in: query, keys: spec.checkinKeys)

        let dynamicKeys = spec.dynamicKeys.compactMap { $0.trimmedNonEmpty }
        let hasDynamic = !dynamicKeys.isEmpty && dynamicKeys.allSatisfy { key in
            query[key]?.trimmedNonEmpty != nil
        }

        let lowerPath = path.lowercased()
        // 明确登录信号（仅匹配 path 或 qrContent 参数，绝不误匹配 host）
        let isExplicitLogin = lowerPath.contains("qrconnect")
            || lowerPath.contains("login")
            || lowerPath.contains("scan-handler")
            || query.keys.contains("qrContent")

        // 宽泛登录路径提示（来自 profile.qr.loginPathHints，仅匹配 path，优先级低于 lessonId）
        let isBroadLoginPath = spec.loginPathHints.contains { hint in
            guard let cleanHint = hint.trimmedNonEmpty else { return false }
            return lowerPath.contains(cleanHint.lowercased())
        }

        let isPureDigits = !clean.isEmpty && clean.allSatisfy { $0.isNumber }

        let kind: TicketKind
        if hasDynamic {
            kind = .DYNAMIC_CHECKIN
        } else if isExplicitLogin {
            kind = .LOGIN
        } else if lessonId != nil || classroomId != nil || isPureDigits {
            kind = .LESSON_ONLY
        } else if isBroadLoginPath {
            kind = .LOGIN
        } else {
            kind = .UNKNOWN
        }

        let resolvedLesson = lessonId ?? ((kind == .LESSON_ONLY && isPureDigits) ? clean : nil)

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

    /// 解析 `a=1&b=2`，值做 UTF-8 安全百分号解码；重复键保留第一个。
    static func queryOf(_ query: String) -> [String: String] {
        let cleaned = substringBefore(query, separator: "#")
        if cleaned.trimmed.isEmpty {
            return [:]
        }
        var out: [String: String] = [:]
        for pair in cleaned.split(separator: "&", omittingEmptySubsequences: false) {
            let text = String(pair)
            if text.trimmed.isEmpty { continue }
            let key: String
            let value: String
            if let eq = text.firstIndex(of: "=") {
                key = String(text[..<eq])
                value = String(text[text.index(after: eq)...])
            } else {
                key = text
                value = ""
            }
            let decodedKey = decode(key)
            if !decodedKey.trimmed.isEmpty && out[decodedKey] == nil {
                out[decodedKey] = decode(value)
            }
        }
        return out
    }

    /// UTF-8 安全百分号解码：`+` -> 空格，`%XX` 按字节拼接，完整保留多字节中文。
    static func decode(_ value: String) -> String {
        if !value.contains("%") && !value.contains("+") {
            return value
        }
        let bytes = Array(value.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x2B {
                out.append(0x20)
                index += 1
            } else if byte == 0x25 && index + 2 < bytes.count {
                if let high = hexValue(bytes[index + 1]), let low = hexValue(bytes[index + 2]) {
                    out.append((high << 4) | low)
                    index += 3
                } else {
                    out.append(byte)
                    index += 1
                }
            } else {
                out.append(byte)
                index += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func extractScheme(_ url: String) -> String? {
        guard let range = url.range(of: "://"), range.lowerBound > url.startIndex else {
            return nil
        }
        let scheme = String(url[..<range.lowerBound])
        let valid = scheme.unicodeScalars.allSatisfy { scalar in
            let v = scalar.value
            return (v >= 0x30 && v <= 0x39)
                || (v >= 0x41 && v <= 0x5A)
                || (v >= 0x61 && v <= 0x7A)
                || v == 0x2B || v == 0x2D || v == 0x2E
        }
        return valid ? scheme.lowercased() : nil
    }

    /// 提取主机名，保留显式端口号与 IPv6 方括号格式（统一小写）。
    static func extractHost(_ url: String) -> String? {
        let rest = afterScheme(url)
        if rest.isEmpty { return nil }
        let authority: String
        if let end = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            authority = String(rest[..<end])
        } else {
            authority = rest
        }
        let hostPort: String
        if let at = authority.lastIndex(of: "@") {
            hostPort = String(authority[authority.index(after: at)...]).trimmed
        } else {
            hostPort = authority.trimmed
        }
        if hostPort.isEmpty { return nil }

        if hostPort.hasPrefix("[") {
            guard let close = hostPort.firstIndex(of: "]"),
                  hostPort.distance(from: hostPort.startIndex, to: close) > 1 else {
                return nil
            }
            let afterBracket = String(hostPort[hostPort.index(after: close)...])
            if !afterBracket.isEmpty {
                guard afterBracket.hasPrefix(":"),
                      let port = Int(afterBracket.dropFirst()),
                      (1...65535).contains(port) else {
                    return nil
                }
            }
            return hostPort.lowercased()
        }

        if let colon = hostPort.firstIndex(of: ":") {
            let hostPart = String(hostPort[..<colon])
            let portPart = String(hostPort[hostPort.index(after: colon)...])
            guard !hostPart.trimmed.isEmpty,
                  let port = Int(portPart),
                  (1...65535).contains(port) else {
                return nil
            }
            return "\(hostPart.lowercased()):\(port)"
        }
        return hostPort.lowercased()
    }

    static func extractPath(_ url: String) -> String {
        let rest = afterScheme(url)
        if rest.isEmpty { return "" }
        let beforeQueryOrFrag = substringBefore(substringBefore(rest, separator: "#"), separator: "?")
        guard let slash = beforeQueryOrFrag.firstIndex(of: "/") else {
            return "/"
        }
        return String(beforeQueryOrFrag[slash...])
    }

    // MARK: 内部工具

    private static func resolveUrl(_ clean: String, spec: QrSpec, profile: ProtocolProfile) -> String? {
        if let range = clean.range(of: "://"), range.lowerBound > clean.startIndex {
            let scheme = String(clean[..<range.lowerBound])
            let allowed = spec.schemes.contains { $0.caseInsensitiveCompare(scheme) == .orderedSame }
            return allowed ? clean : nil
        }

        // 支持无 scheme URL（如 www.yuketang.cn/v2/web/studentLog/... 或 127.0.0.1:8787/checkin?...）
        let sepIndex = clean.firstIndex(where: { $0 == "/" || $0 == "?" })
        let head = sepIndex.map { String(clean[..<$0]) } ?? clean
        if head.isEmpty || head.contains(where: { $0 == "=" || $0 == "&" || $0.isWhitespace }) {
            return nil
        }

        let hasPathOrQuery = sepIndex != nil
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

    private static func firstValue(in query: [String: String], keys: [String]) -> String? {
        for key in keys {
            if let value = query[key]?.trimmedNonEmpty {
                return value
            }
        }
        return nil
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }

    private static func substringBefore(_ text: String, separator: Character) -> String {
        guard let index = text.firstIndex(of: separator) else { return text }
        return String(text[..<index])
    }

    private static func substringAfter(_ text: String, separator: Character) -> String {
        guard let index = text.firstIndex(of: separator) else { return "" }
        return String(text[text.index(after: index)...])
    }

    /// 仅裁掉开头指定字符（绝不裁末尾 `?` 签名）。
    private static func trimLeading(_ text: String, characters: String) -> String {
        let set = Set(characters)
        var slice = Substring(text)
        while let first = slice.first, set.contains(first) {
            slice = slice.dropFirst()
        }
        return String(slice)
    }

    private static func afterScheme(_ url: String) -> String {
        guard let range = url.range(of: "://") else { return "" }
        return String(url[range.upperBound...])
    }
}
