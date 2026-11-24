//
//  AccountVaultStore.swift
//  RainCheck
//
//  安全账号仓库（Keychain + 加密保护元信息）：
//   - 敏感凭据（bearer / sessionId / csrfToken）严格存入 iOS Keychain
//     （kSecClassGenericPassword + kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly）；
//   - 非敏感账号元信息落盘至 Application Support/RainCheck/accounts_meta.json，
//     启用 .completeFileProtection 并显式设置 isExcludedFromBackup = true（不随 iCloud 备份）；
//   - 自动迁移旧版明文 Application Support/accounts.json 并安全清理旧文件；
//   - 凭据回写仅更新仍存在于账号池中的账号，绝不复活已删账号或覆写用户编辑的 label/enabled。
//

import Foundation
import Security

// MARK: - 凭据载荷与 Keychain 抽象

struct AccountSecret: Codable, Hashable, Sendable {
    var bearer: String?
    var sessionId: String?
    var csrfToken: String?

    var isEmpty: Bool {
        (bearer?.trimmedNonEmpty == nil)
            && (sessionId?.trimmedNonEmpty == nil)
            && (csrfToken?.trimmedNonEmpty == nil)
    }
}

protocol CredentialSecretStore: Sendable {
    func readSecret(for accountId: String) -> AccountSecret?
    func writeSecret(_ secret: AccountSecret, for accountId: String)
    func deleteSecret(for accountId: String)
}

/// iOS Keychain 凭据存储（仅本机、首次解锁后可访问，永不同步 iCloud Keychain）。
final class KeychainSecretStore: CredentialSecretStore {
    let service: String

    init(service: String = "cn.raincheck.ios.credentials") {
        self.service = service
    }

    func readSecret(for accountId: String) -> AccountSecret? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: accountId,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(AccountSecret.self, from: data)
    }

    func writeSecret(_ secret: AccountSecret, for accountId: String) {
        if secret.isEmpty {
            deleteSecret(for: accountId)
            return
        }
        guard let data = try? JSONEncoder().encode(secret) else {
            return
        }
        let baseQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: accountId
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData] = data
            addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            _ = SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    func deleteSecret(for accountId: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: accountId
        ]
        _ = SecItemDelete(query as CFDictionary)
    }
}

/// 内存态密钥库（供单元测试与无 Keychain 沙箱环境使用）。
final class InMemorySecretStore: CredentialSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: AccountSecret] = [:]

    func readSecret(for accountId: String) -> AccountSecret? {
        lock.lock()
        defer { lock.unlock() }
        return storage[accountId]
    }

    func writeSecret(_ secret: AccountSecret, for accountId: String) {
        lock.lock()
        defer { lock.unlock() }
        if secret.isEmpty {
            storage.removeValue(forKey: accountId)
        } else {
            storage[accountId] = secret
        }
    }

    func deleteSecret(for accountId: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: accountId)
    }
}

// MARK: - 落盘元信息（严格不含任何凭据）

struct AccountMetadata: Codable, Hashable, Sendable {
    var id: String
    var label: String
    var host: String
    var scheme: String
    var enabled: Bool
    var createdAt: Int64
    var lastOkAt: Int64?
    var userId: String?
    var note: String

    init(from account: Account) {
        self.id = account.id
        self.label = account.label
        self.host = account.host
        self.scheme = account.scheme
        self.enabled = account.enabled
        self.createdAt = account.createdAt
        self.lastOkAt = account.lastOkAt
        self.userId = account.userId
        self.note = account.note
    }

    func materialized(secret: AccountSecret?) -> Account {
        Account(
            id: id,
            label: label,
            host: host,
            scheme: scheme,
            bearer: secret?.bearer?.trimmedNonEmpty,
            sessionId: secret?.sessionId?.trimmedNonEmpty,
            csrfToken: secret?.csrfToken?.trimmedNonEmpty,
            enabled: enabled,
            createdAt: createdAt,
            lastOkAt: lastOkAt,
            userId: userId,
            note: note
        )
    }
}

// MARK: - AccountVaultStore

struct AccountVaultStore: Sendable {
    static let metadataFileName = "accounts_meta.json"
    static let legacyFileName = "accounts.json"

    let metadataURL: URL
    let legacyURL: URL?
    let secrets: any CredentialSecretStore

    init(
        metadataURL: URL,
        legacyURL: URL? = nil,
        secrets: any CredentialSecretStore = KeychainSecretStore()
    ) {
        self.metadataURL = metadataURL
        self.legacyURL = legacyURL
        self.secrets = secrets
    }

    /// 默认仓库：`Application Support/RainCheck/accounts_meta.json` + Keychain。
    static func appDefault() -> AccountVaultStore {
        let manager = FileManager.default
        let appSupport: URL
        if let dir = try? manager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            appSupport = dir
        } else {
            appSupport = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        }
        let vaultDir = appSupport.appendingPathComponent("RainCheck", isDirectory: true)
        return AccountVaultStore(
            metadataURL: vaultDir.appendingPathComponent(metadataFileName),
            legacyURL: appSupport.appendingPathComponent(legacyFileName),
            secrets: KeychainSecretStore()
        )
    }

    var storageSummary: String {
        "Keychain（本机） + 受保护元信息（不随 iCloud 备份）"
    }

    // MARK: 读写与迁移

    func load() -> [Account] {
        migrateLegacyIfNeeded()
        guard let data = try? Data(contentsOf: metadataURL) else {
            return []
        }
        guard let records = try? JSONDecoder().decode([AccountMetadata].self, from: data) else {
            return []
        }
        return records.map { record in
            record.materialized(secret: secrets.readSecret(for: record.id))
        }
    }

    func save(_ accounts: [Account]) {
        // 先收集当前落盘的旧 ID，以便移除被删除账号的 Keychain 条目
        let previousIds: Set<String>
        if let existingData = try? Data(contentsOf: metadataURL),
           let existing = try? JSONDecoder().decode([AccountMetadata].self, from: existingData) {
            previousIds = Set(existing.map { $0.id })
        } else {
            previousIds = []
        }

        let currentIds = Set(accounts.map { $0.id })
        for removedId in previousIds.subtracting(currentIds) {
            secrets.deleteSecret(for: removedId)
        }

        for account in accounts {
            let secret = AccountSecret(
                bearer: account.bearer?.trimmedNonEmpty,
                sessionId: account.sessionId?.trimmedNonEmpty,
                csrfToken: account.csrfToken?.trimmedNonEmpty
            )
            secrets.writeSecret(secret, for: account.id)
        }

        let metadata = accounts.map { AccountMetadata(from: $0) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(metadata) else {
            return
        }

        let directory = metadataURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        excludeFromBackup(directory)

        do {
            try data.write(to: metadataURL, options: [.atomic, .completeFileProtection])
            excludeFromBackup(metadataURL)
        } catch {
            // 极端情况下（如测试临时卷不支持 FileProtection），回退到原子写入并仍排除备份
            try? data.write(to: metadataURL, options: .atomic)
            excludeFromBackup(metadataURL)
        }
    }

    private func migrateLegacyIfNeeded() {
        guard let legacyURL,
              FileManager.default.fileExists(atPath: legacyURL.path) else {
            return
        }
        defer {
            try? FileManager.default.removeItem(at: legacyURL)
        }
        guard !FileManager.default.fileExists(atPath: metadataURL.path),
              let data = try? Data(contentsOf: legacyURL) else {
            return
        }
        let legacyAccounts = AccountVaultStore.decodePortableAccounts(data)
        if !legacyAccounts.isEmpty {
            save(legacyAccounts)
        }
    }

    private func excludeFromBackup(_ url: URL) {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutableURL.setResourceValues(values)
    }

    /// 兼容跨端裸数组与 `{"accounts": [...]}` 结构（用于旧版迁移与跨端导入）。
    static func decodePortableAccounts(_ data: Data) -> [Account] {
        let decoder = JSONDecoder()
        if let list = try? decoder.decode([Account].self, from: data) {
            return list
        }
        if let wrapper = try? decoder.decode(PortableWrapper.self, from: data) {
            return wrapper.accounts
        }
        return []
    }

    struct PortableWrapper: Codable, Sendable {
        var version: Int?
        var accounts: [Account]
    }

    // MARK: 纯函数式集合变换

    static func upserting(_ accounts: [Account], with account: Account) -> [Account] {
        var list = accounts
        if let index = list.firstIndex(where: { $0.id == account.id }) {
            list[index] = account
        } else {
            list.append(account)
        }
        return list
    }

    static func removing(_ accounts: [Account], id: String) -> [Account] {
        accounts.filter { $0.id != id }
    }

    static func settingEnabled(_ accounts: [Account], id: String, enabled: Bool) -> [Account] {
        var list = accounts
        if let index = list.firstIndex(where: { $0.id == id }) {
            list[index].enabled = enabled
        }
        return list
    }

    /// 仅对仍存在于当前账号池中的账号回写刷新后的凭据，绝不复活已删账号，也不覆盖用户改动的 label / enabled。
    static func applyingRefreshedCredentials(
        to accounts: [Account],
        updates: [Account]
    ) -> (accounts: [Account], appliedCount: Int) {
        var list = accounts
        var count = 0
        for updated in updates where updated.hasCredential {
            guard let index = list.firstIndex(where: { $0.id == updated.id }) else {
                continue
            }
            var target = list[index]
            var changed = false
            if let bearer = updated.bearer?.trimmedNonEmpty, bearer != target.bearer {
                target.bearer = bearer
                changed = true
            }
            if let sessionId = updated.sessionId?.trimmedNonEmpty, sessionId != target.sessionId {
                target.sessionId = sessionId
                changed = true
            }
            if let csrf = updated.csrfToken?.trimmedNonEmpty, csrf != target.csrfToken {
                target.csrfToken = csrf
                changed = true
            }
            if let lastOk = updated.lastOkAt, lastOk > (target.lastOkAt ?? 0) {
                target.lastOkAt = lastOk
            }
            if changed {
                list[index] = target
                count += 1
            }
        }
        return (list, count)
    }

    // MARK: 凭据与自定义站点清洗

    struct ParsedCredentials: Equatable, Sendable {
        var bearer: String?
        var sessionId: String?
        var csrfToken: String?

        var hasAny: Bool {
            (bearer?.trimmedNonEmpty != nil) || (sessionId?.trimmedNonEmpty != nil)
        }
    }

    /// 解析用户粘贴的凭据：自动剥离 `Authorization:` / `Bearer ` 前缀、解析 `Cookie:` 与 `sessionid/csrftoken`；
    /// 严禁把仅空白或仅有前缀的字符串当作有效凭据。
    static func parseCredentials(_ text: String) -> ParsedCredentials {
        let raw = text.trimmed
        if raw.isEmpty {
            return ParsedCredentials()
        }

        var bearer: String?
        var sessionId: String?
        var csrf: String?

        let lower = raw.lowercased()
        let looksLikeCookie = lower.contains("sessionid=")
            || lower.contains("sid=")
            || lower.contains("csrftoken=")
            || lower.hasPrefix("cookie:")

        if looksLikeCookie {
            for line in raw.components(separatedBy: .newlines) {
                var body = line.trimmed
                if body.isEmpty { continue }
                let lineLower = body.lowercased()
                if lineLower.hasPrefix("authorization:") {
                    let value = String(body.dropFirst("authorization:".count)).trimmed
                    bearer = stripBearerPrefix(value)
                    continue
                }
                if lineLower.hasPrefix("cookie:") {
                    body = String(body.dropFirst("cookie:".count))
                }
                for chunk in body.split(whereSeparator: { $0 == ";" || $0 == "&" }) {
                    let pair = String(chunk).trimmed
                    guard let index = pair.firstIndex(of: "=") else { continue }
                    let name = String(pair[pair.startIndex..<index]).trimmed.lowercased()
                    let value = String(pair[pair.index(after: index)...]).trimmed
                    if value.isEmpty { continue }
                    switch name {
                    case "sessionid", "sid":
                        sessionId = value
                    case "csrftoken":
                        csrf = value
                    default:
                        continue
                    }
                }
            }
            return ParsedCredentials(bearer: bearer, sessionId: sessionId, csrfToken: csrf)
        }

        var candidate = raw
        if lower.hasPrefix("authorization:") {
            candidate = String(candidate.dropFirst("authorization:".count)).trimmed
        }
        bearer = stripBearerPrefix(candidate)
        return ParsedCredentials(bearer: bearer, sessionId: nil, csrfToken: nil)
    }

    static func stripBearerPrefix(_ value: String) -> String? {
        var text = value.trimmed
        if text.lowercased().hasPrefix("bearer ") {
            text = String(text.dropFirst("bearer ".count)).trimmed
        } else if text.lowercased() == "bearer" {
            return nil
        }
        return text.isEmpty ? nil : text
    }

    /// 清洗自定义 host：自动剥离 `https://` / `http://` 前缀、路径与尾部 `/`。
    static func normalizeCustomHost(_ rawHost: String, fallbackScheme: String) -> (host: String, scheme: String)? {
        var text = rawHost.trimmed
        guard !text.isEmpty else { return nil }

        var scheme = fallbackScheme.lowercased() == "http" ? "http" : "https"
        if let range = text.range(of: "://") {
            let prefix = String(text[..<range.lowerBound]).lowercased()
            if prefix == "http" || prefix == "https" {
                scheme = prefix
            }
            text = String(text[range.upperBound...])
        }
        if let slash = text.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            text = String(text[..<slash])
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !text.isEmpty, !text.contains(" ") else {
            return nil
        }
        return (text, scheme)
    }
}
