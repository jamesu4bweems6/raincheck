import Foundation
import Security

/// 账号持久化仓库协议（要求全方法线程安全且符合 `Sendable`）。
protocol AccountVaulting: Sendable {
    func load() -> [Account]
    func save(_ accounts: [Account]) throws
    func upsert(_ account: Account) throws
    func remove(id: String) throws
}

/// 敏感凭据底层存储抽象（生产默认走 iOS Keychain；单测可注入内存实现规避 Simulator 权限波动）。
protocol SecretStorage: Sendable {
    func readSecret(accountId: String) throws -> Data?
    func writeSecret(_ data: Data, accountId: String) throws
    func deleteSecret(accountId: String) throws
    func deleteAllSecrets() throws
}

enum KeychainVaultError: Error, LocalizedError, Equatable, Sendable {
    case keychainFailure(OSStatus)
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .keychainFailure(let status):
            return "Keychain 操作失败 (OSStatus=\(status))"
        case .encodingFailed:
            return "账号数据序列化失败"
        }
    }
}

/// iOS Keychain 凭据存储实现，严格使用 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`。
final class KeychainSecretStorage: SecretStorage, Sendable {
    let service: String

    init(service: String = "cn.raincheck.ios.accounts") {
        self.service = service
    }

    func readSecret(accountId: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainVaultError.keychainFailure(status)
        }
        return result as? Data
    }

    func writeSecret(_ data: Data, accountId: String) throws {
        let lookupQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountId
        ]
        let attributesToUpdate: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(lookupQuery as CFDictionary, attributesToUpdate as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            throw KeychainVaultError.keychainFailure(updateStatus)
        }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountId,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainVaultError.keychainFailure(addStatus)
        }
    }

    func deleteSecret(accountId: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountId
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainVaultError.keychainFailure(status)
        }
    }

    func deleteAllSecrets() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainVaultError.keychainFailure(status)
        }
    }
}

/// 纯内存凭据存储实现（供单元测试确定性验证 `KeychainVault` 拆分持久化逻辑）。
final class InMemorySecretStorage: SecretStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: Data] = [:]

    init() {}

    func readSecret(accountId: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return secrets[accountId]
    }

    func writeSecret(_ data: Data, accountId: String) throws {
        lock.lock()
        defer { lock.unlock() }
        secrets[accountId] = data
    }

    func deleteSecret(accountId: String) throws {
        lock.lock()
        defer { lock.unlock() }
        secrets.removeValue(forKey: accountId)
    }

    func deleteAllSecrets() throws {
        lock.lock()
        defer { lock.unlock() }
        secrets.removeAll()
    }

    func storedAccountIds() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(secrets.keys)
    }
}

/// 生产级分离存储仓库：
/// - 敏感凭据（`bearer` / `sessionId` / `csrfToken`）独立写入 Keychain（`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`）
/// - 非敏感元数据写入 Application Support JSON（`.completeFileProtection` + `isExcludedFromBackup = true`）
/// - 全程由 `NSLock` 串行化，杜绝并发读写竞态与丢更新。
final class KeychainVault: AccountVaulting, @unchecked Sendable {
    let service: String
    let metadataURL: URL
    private let secretStorage: any SecretStorage
    private let lock = NSLock()

    private struct AccountMetadataRecord: Codable {
        let id: String
        let label: String
        let host: String
        let scheme: String
        let enabled: Bool
        let createdAt: Int64
        let lastOkAt: Int64?
        let userId: String?
        let note: String
    }

    private struct AccountSecretPayload: Codable {
        let bearer: String?
        let sessionId: String?
        let csrfToken: String?

        var isEmpty: Bool {
            let bEmpty = bearer?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
            let sEmpty = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
            let cEmpty = csrfToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
            return bEmpty && sEmpty && cEmpty
        }
    }

    init(
        service: String = "cn.raincheck.ios.accounts",
        metadataURL: URL? = nil,
        secretStorage: (any SecretStorage)? = nil
    ) {
        self.service = service
        self.metadataURL = metadataURL ?? Self.defaultMetadataURL()
        self.secretStorage = secretStorage ?? KeychainSecretStorage(service: service)
    }

    func load() -> [Account] {
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked()
    }

    func save(_ accounts: [Account]) throws {
        lock.lock()
        defer { lock.unlock() }
        try saveUnlocked(accounts)
    }

    func upsert(_ account: Account) throws {
        lock.lock()
        defer { lock.unlock() }
        var current = loadUnlocked()
        if let idx = current.firstIndex(where: { $0.id == account.id }) {
            current[idx] = account
        } else {
            current.append(account)
        }
        try saveUnlocked(current)
    }

    func remove(id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let remaining = loadUnlocked().filter { $0.id != id }
        try saveUnlocked(remaining)
        try secretStorage.deleteSecret(accountId: id)
    }

    // MARK: - Locked Internals (caller must hold `lock`)

    private func loadUnlocked() -> [Account] {
        let records = readMetadataRecordsUnlocked()
        let decoder = JSONDecoder()

        return records.map { record in
            let secret: AccountSecretPayload?
            if let secretData = try? secretStorage.readSecret(accountId: record.id) {
                secret = try? decoder.decode(AccountSecretPayload.self, from: secretData)
            } else {
                secret = nil
            }
            return Account(
                id: record.id,
                label: record.label,
                host: record.host,
                scheme: record.scheme,
                bearer: secret?.bearer,
                sessionId: secret?.sessionId,
                csrfToken: secret?.csrfToken,
                enabled: record.enabled,
                createdAt: record.createdAt,
                lastOkAt: record.lastOkAt,
                userId: record.userId,
                note: record.note
            )
        }
    }

    private func saveUnlocked(_ accounts: [Account]) throws {
        let previousIds = Set(readMetadataRecordsUnlocked().map(\.id))
        let newIds = Set(accounts.map(\.id))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        // 1. 先同步凭据到 Keychain（或安全存储）
        for account in accounts {
            let payload = AccountSecretPayload(
                bearer: account.bearer,
                sessionId: account.sessionId,
                csrfToken: account.csrfToken
            )
            if payload.isEmpty {
                try secretStorage.deleteSecret(accountId: account.id)
            } else {
                let secretData = try encoder.encode(payload)
                try secretStorage.writeSecret(secretData, accountId: account.id)
            }
        }

        // 2. 仅将脱敏元数据落盘（绝不写入 bearer / sessionId / csrfToken）
        let records = accounts.map { account in
            AccountMetadataRecord(
                id: account.id,
                label: account.label,
                host: account.host,
                scheme: account.scheme,
                enabled: account.enabled,
                createdAt: account.createdAt,
                lastOkAt: account.lastOkAt,
                userId: account.userId,
                note: account.note
            )
        }

        let directoryURL = metadataURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        excludeFromBackup(directoryURL)

        let metadataData = try encoder.encode(records)
        try metadataData.write(to: metadataURL, options: [.atomic, .completeFileProtection])
        excludeFromBackup(metadataURL)

        // 3. 清理已移除账号遗留的 Keychain 条目
        let removedIds = previousIds.subtracting(newIds)
        for orphanId in removedIds {
            try? secretStorage.deleteSecret(accountId: orphanId)
        }
    }

    private func readMetadataRecordsUnlocked() -> [AccountMetadataRecord] {
        guard FileManager.default.fileExists(atPath: metadataURL.path),
              let data = try? Data(contentsOf: metadataURL),
              !data.isEmpty,
              let records = try? JSONDecoder().decode([AccountMetadataRecord].self, from: data) else {
            return []
        }
        return records
    }

    private func excludeFromBackup(_ url: URL) {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutableURL.setResourceValues(values)
    }

    private static func defaultMetadataURL() -> URL {
        let baseDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseDir
            .appendingPathComponent("RainCheck", isDirectory: true)
            .appendingPathComponent("accounts_metadata.json", isDirectory: false)
    }
}

/// 纯内存线程安全账号仓库（用于单元测试与 SwiftUI 预览）。
final class InMemoryAccountVault: AccountVaulting, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Account]

    init(initial: [Account] = []) {
        self.storage = initial
    }

    func load() -> [Account] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func save(_ accounts: [Account]) throws {
        lock.lock()
        defer { lock.unlock() }
        storage = accounts
    }

    func upsert(_ account: Account) throws {
        lock.lock()
        defer { lock.unlock() }
        if let idx = storage.firstIndex(where: { $0.id == account.id }) {
            storage[idx] = account
        } else {
            storage.append(account)
        }
    }

    func remove(id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll { $0.id == id }
    }
}

// MARK: - Check-In History Persistence

/// 扫码签到历史持久化协议（要求线程安全且符合 `Sendable`）。
protocol CheckInHistoryStoring: Sendable {
    func load() -> [CheckInHistoryEntry]
    func save(_ entries: [CheckInHistoryEntry])
}

/// 文件级扫码签到历史存储：
/// - 写入 Application Support `RainCheck/checkin_history.json`（`.atomic` + `.completeFileProtection` + `isExcludedFromBackup = true`）
/// - 仅保存经 `SignResult.CodingKeys` 脱敏的历史记录，最多保留最新 `maxEntries` 条（默认 200）
/// - 全程由 `NSLock` 串行化，避免并发读写竞态。
final class FileCheckInHistoryStore: CheckInHistoryStoring, @unchecked Sendable {
    let fileURL: URL
    let maxEntries: Int
    private let lock = NSLock()

    init(
        fileURL: URL? = nil,
        maxEntries: Int = 200
    ) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        self.maxEntries = max(1, maxEntries)
    }

    func load() -> [CheckInHistoryEntry] {
        lock.lock()
        defer { lock.unlock() }

        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              !data.isEmpty,
              let entries = try? JSONDecoder().decode([CheckInHistoryEntry].self, from: data) else {
            return []
        }
        return Array(entries.prefix(maxEntries))
    }

    func save(_ entries: [CheckInHistoryEntry]) {
        lock.lock()
        defer { lock.unlock() }

        let bounded = Array(entries.prefix(maxEntries))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        guard let data = try? encoder.encode(bounded) else {
            return
        }

        let directoryURL = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        excludeFromBackup(directoryURL)

        try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        excludeFromBackup(fileURL)
    }

    private func excludeFromBackup(_ url: URL) {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutableURL.setResourceValues(values)
    }

    private static func defaultFileURL() -> URL {
        let baseDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseDir
            .appendingPathComponent("RainCheck", isDirectory: true)
            .appendingPathComponent("checkin_history.json", isDirectory: false)
    }
}

/// 纯内存线程安全历史存储实现（用于 XCTest 隔离磁盘副作用与 SwiftUI 预览）。
final class InMemoryCheckInHistoryStore: CheckInHistoryStoring, @unchecked Sendable {
    let maxEntries: Int
    private let lock = NSLock()
    private var storage: [CheckInHistoryEntry]

    init(
        initial: [CheckInHistoryEntry] = [],
        maxEntries: Int = 200
    ) {
        let safeMax = max(1, maxEntries)
        self.maxEntries = safeMax
        self.storage = Array(initial.prefix(safeMax))
    }

    func load() -> [CheckInHistoryEntry] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func save(_ entries: [CheckInHistoryEntry]) {
        lock.lock()
        defer { lock.unlock() }
        storage = Array(entries.prefix(maxEntries))
    }
}
