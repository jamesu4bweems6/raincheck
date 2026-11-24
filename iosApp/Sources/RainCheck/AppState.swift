//
//  AppState.swift
//  RainCheck
//
//  @MainActor 应用状态容器：
//   - 接入 Keychain 安全仓库（AccountVaultStore）；
//   - 修复旧版「全不选 = 全选」反直觉逻辑（明确勾选集，提供全选 / 反选 / 清空）；
//   - 修复 `verifyAccounts()` 跨 await 用旧快照覆写期间增删改的竞态；
//   - 修复 `sign()` 会话回写复活已删账号或覆写 label/enabled 的问题；
//   - 报文实验室「重试失败项」严格沿用 `report.ticket`，不混用新扫的码、不覆写用户 options；
//   - 缓存零凭据 JSON 导出文本，绝不在 SwiftUI `body` 每次重绘重新编码。
//

import Foundation
import SwiftUI

enum AppTab: Int, Hashable, CaseIterable, Sendable {
    case studio = 0
    case vault = 1
    case telemetry = 2

    var title: String {
        switch self {
        case .studio: return "签到台"
        case .vault: return "账号舱"
        case .telemetry: return "报文实验室"
        }
    }

    var symbolName: String {
        switch self {
        case .studio: return "qrcode.viewfinder"
        case .vault: return "person.2.crop.square.stack"
        case .telemetry: return "waveform.path.ecg.rectangle"
        }
    }
}

struct SignProgress: Equatable, Sendable {
    var total: Int
    var completed: Int
    var succeeded: Int
    var failed: Int

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(max(Double(completed) / Double(total), 0), 1)
    }
}

@MainActor
final class AppState: ObservableObject {
    // MARK: 依赖

    let profileStore: ProfileStore
    let vaultStore: AccountVaultStore
    let api: RainCheckApi
    let engine: SignInEngine
    let login: LoginService

    // MARK: 响应式状态

    @Published private(set) var accounts: [Account] = []
    @Published var activeTab: AppTab = .studio
    @Published var ticket: QrTicket?
    @Published var scannedText: String = ""
    /// 明确勾选参与签到的账号 ID 集合（不再把空集合反直觉解释为全选）。
    @Published var selectedAccountIds: Set<String> = []
    @Published private(set) var report: SignBatchReport?
    @Published private(set) var cachedExportJSON: String = "{\n  \"msg\": \"还没有签到结果\"\n}"
    @Published private(set) var running: Bool = false
    @Published private(set) var verifying: Bool = false
    @Published private(set) var progress: SignProgress?
    @Published private(set) var log: [String] = []
    @Published var options: SignOptions = SignOptions()
    @Published var notice: String?

    init(
        profileStore: ProfileStore = .bundled(),
        vaultStore: AccountVaultStore = .appDefault(),
        api: RainCheckApi? = nil
    ) {
        let resolvedApi = api ?? RainCheckApi(profile: profileStore.profile)
        self.profileStore = profileStore
        self.vaultStore = vaultStore
        self.api = resolvedApi
        self.engine = SignInEngine(api: resolvedApi, profile: profileStore.profile)
        self.login = LoginService(api: resolvedApi, profile: profileStore.profile)

        let loaded = vaultStore.load()
        self.accounts = loaded
        self.selectedAccountIds = Set(loaded.filter { $0.enabled }.map { $0.id })
        self.notice = profileStore.loadError
    }

    // MARK: 账号池与健康度

    var enabledAccounts: [Account] {
        accounts.filter { $0.enabled }
    }

    var healthyAccountCount: Int {
        accounts.filter { $0.enabled && $0.hasCredential && $0.note.isEmpty }.count
    }

    var renewalNeededCount: Int {
        accounts.filter { $0.enabled && (!$0.hasCredential || !$0.note.isEmpty) }.count
    }

    var disabledAccountCount: Int {
        accounts.filter { !$0.enabled }.count
    }

    func account(id: String) -> Account? {
        accounts.first { $0.id == id }
    }

    func upsert(_ account: Account) {
        let isNew = !accounts.contains { $0.id == account.id }
        accounts = AccountVaultStore.upserting(accounts, with: account)
        vaultStore.save(accounts)
        if isNew && account.enabled {
            selectedAccountIds.insert(account.id)
        } else if !account.enabled {
            selectedAccountIds.remove(account.id)
        }
        pruneSelection()
    }

    func delete(id: String) {
        accounts = AccountVaultStore.removing(accounts, id: id)
        selectedAccountIds.remove(id)
        vaultStore.save(accounts)
    }

    func setEnabled(id: String, enabled: Bool) {
        accounts = AccountVaultStore.settingEnabled(accounts, id: id, enabled: enabled)
        if enabled {
            selectedAccountIds.insert(id)
        } else {
            selectedAccountIds.remove(id)
        }
        vaultStore.save(accounts)
    }

    func verify(account: Account) async -> Account? {
        await login.verify(account: account)
    }

    /// 校验单个现存账号并原地安全写回：若校验期间账号已被删除则放弃写回，绝不复活已删账号或覆写当前 `enabled`。
    /// 返回 `true` 校验通过，`false` 校验失败，`nil` 账号已不存在。
    @discardableResult
    func verifyAccount(id: String) async -> Bool? {
        guard let snapshot = account(id: id) else { return nil }
        guard snapshot.hasCredential else {
            updateAccountInPlace(id: id) { current in
                current.note = "未配置有效凭据"
            }
            vaultStore.save(accounts)
            notice = "「\(snapshot.label)」未配置有效凭据"
            return false
        }

        let verified = await login.verify(account: snapshot)
        guard account(id: id) != nil else {
            // 校验期间账号已被删除，放弃写回防止复活
            return nil
        }

        if let verified {
            updateAccountInPlace(id: id) { current in
                if let name = verified.label.trimmedNonEmpty, !name.hasPrefix("账号 ") {
                    current.label = name
                }
                if let uid = verified.userId?.trimmedNonEmpty {
                    current.userId = uid
                }
                if let bearer = verified.bearer?.trimmedNonEmpty {
                    current.bearer = bearer
                }
                if let sid = verified.sessionId?.trimmedNonEmpty {
                    current.sessionId = sid
                }
                if let csrf = verified.csrfToken?.trimmedNonEmpty {
                    current.csrfToken = csrf
                }
                current.lastOkAt = verified.lastOkAt ?? TimeUtil.nowMillis()
                current.note = ""
            }
            vaultStore.save(accounts)
            let displayName = account(id: id)?.label ?? verified.label
            notice = "「\(displayName)」会话校验通过"
            return true
        } else {
            updateAccountInPlace(id: id) { current in
                current.note = "会话校验未通过，建议重新扫码登录"
            }
            vaultStore.save(accounts)
            let displayName = account(id: id)?.label ?? snapshot.label
            notice = "「\(displayName)」会话校验失败"
            return false
        }
    }

    /// 逐个校验账号会话；每次 `await` 后基于当前最新 `accounts` 按 ID 定位写回，绝不覆写期间的增删改。
    func verifyAccounts() async {
        guard !verifying else { return }
        verifying = true
        defer { verifying = false }

        let targetIds = accounts.map { $0.id }
        var passed = 0
        for id in targetIds {
            guard let snapshot = account(id: id) else { continue }
            guard snapshot.hasCredential else {
                updateAccountInPlace(id: id) { item in
                    item.note = "未配置有效凭据"
                }
                continue
            }
            if let verified = await login.verify(account: snapshot) {
                passed += 1
                updateAccountInPlace(id: id) { current in
                    if let name = verified.label.trimmedNonEmpty, !name.hasPrefix("账号 ") {
                        current.label = name
                    }
                    if let uid = verified.userId?.trimmedNonEmpty {
                        current.userId = uid
                    }
                    if let bearer = verified.bearer?.trimmedNonEmpty {
                        current.bearer = bearer
                    }
                    if let sid = verified.sessionId?.trimmedNonEmpty {
                        current.sessionId = sid
                    }
                    if let csrf = verified.csrfToken?.trimmedNonEmpty {
                        current.csrfToken = csrf
                    }
                    current.lastOkAt = verified.lastOkAt ?? TimeUtil.nowMillis()
                    current.note = ""
                }
            } else {
                updateAccountInPlace(id: id) { current in
                    current.note = "会话校验未通过，建议重新扫码登录"
                }
            }
        }
        vaultStore.save(accounts)
        appendLog("账号健康度巡检完成：\(passed) / \(targetIds.count) 个会话有效")
    }

    private func updateAccountInPlace(id: String, mutate: (inout Account) -> Void) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        var copy = accounts[index]
        mutate(&copy)
        accounts[index] = copy
    }

    // MARK: 明确勾选模型（无「全不选=全选」陷阱）

    func isSelected(_ id: String) -> Bool {
        selectedAccountIds.contains(id)
    }

    func toggleSelection(id: String) {
        if selectedAccountIds.contains(id) {
            selectedAccountIds.remove(id)
        } else if let target = account(id: id), target.enabled {
            selectedAccountIds.insert(id)
        }
    }

    func selectAllEnabled() {
        selectedAccountIds = Set(enabledAccounts.map { $0.id })
    }

    func invertSelection() {
        let enabledIds = Set(enabledAccounts.map { $0.id })
        selectedAccountIds = enabledIds.subtracting(selectedAccountIds)
    }

    func clearSelection() {
        selectedAccountIds.removeAll()
    }

    /// 严格只返回「已启用 且 已明确勾选」的账号集合。
    func signTargets() -> [Account] {
        enabledAccounts.filter { selectedAccountIds.contains($0.id) }
    }

    private func pruneSelection() {
        let enabledIds = Set(enabledAccounts.map { $0.id })
        selectedAccountIds = selectedAccountIds.intersection(enabledIds)
    }

    // MARK: 二维码解析与安全检查

    @discardableResult
    func ingest(text: String) -> QrTicket {
        let parsed = QrParser.parse(text, profile: profileStore.profile)
        scannedText = text
        ticket = parsed
        appendLog("解析二维码：\(parsed.kind.displayName) · \(parsed.summary())")
        return parsed
    }

    func clearTicket() {
        ticket = nil
        scannedText = ""
    }

    /// 检查二维码直连 URL 是否存在恶意外部域名或不安全明文 HTTP 风险。
    func qrSecurityWarning(for ticket: QrTicket) -> String? {
        guard let url = ticket.url?.trimmedNonEmpty else { return nil }
        // 若当前已勾选账号中任一账号同源允许，则不算风险；否则返回白名单校验原因
        let candidates = signTargets()
        if candidates.isEmpty {
            return profileStore.profile.validateQrUrl(url, account: nil)
        }
        for acc in candidates {
            if profileStore.profile.validateQrUrl(url, account: acc) == nil {
                return nil
            }
        }
        return profileStore.profile.validateQrUrl(url, account: candidates.first)
    }

    // MARK: 并发签到与精准失败重试

    func sign() async {
        guard !running else { return }
        guard let ticket else {
            notice = "先扫码或粘贴课堂二维码"
            return
        }
        if ticket.kind == .LOGIN {
            notice = "检测到登录二维码，请切换到「账号舱」使用扫码登录"
            return
        }
        let targets = signTargets()
        guard !targets.isEmpty else {
            notice = enabledAccounts.isEmpty
                ? "账号舱暂无已启用账号，请先添加并启用至少一个账号"
                : "请先勾选至少一个参与签到的账号"
            return
        }
        await executeBatch(targets: targets, ticket: ticket, runOptions: options, switchToTelemetry: true)
    }

    /// 仅针对 `sourceReport` 中未成功的账号重试，严格沿用 `sourceReport.ticket`，绝不混用新码或覆写用户选项。
    func retryFailed(from sourceReport: SignBatchReport) async {
        guard !running else { return }
        let failedIds = Set(sourceReport.results.filter { !$0.ok && $0.state != .DRY_RUN }.map { $0.accountId })
        let retryTargets = accounts.filter { failedIds.contains($0.id) && $0.hasCredential }
        guard !retryTargets.isEmpty else {
            notice = "没有可重试的失败账号（可能已被删除或缺少凭据）"
            return
        }
        // 以临时启用副本发给引擎，绝不修改账号池本身的 enabled 状态
        let runnable = retryTargets.map { acc -> Account in
            var copy = acc
            copy.enabled = true
            return copy
        }
        var retryOptions = options
        retryOptions.dryRun = false
        await executeBatch(
            targets: runnable,
            ticket: sourceReport.ticket,
            runOptions: retryOptions,
            switchToTelemetry: false
        )
    }

    private func executeBatch(
        targets: [Account],
        ticket: QrTicket,
        runOptions: SignOptions,
        switchToTelemetry: Bool
    ) async {
        running = true
        notice = nil
        log.removeAll()
        progress = SignProgress(total: targets.count, completed: 0, succeeded: 0, failed: 0)

        let modeTag = runOptions.dryRun ? " · 演练模式（零发包）" : ""
        appendLog("开始签到：\(ticket.summary())，账号 \(targets.count) 个，并发 \(runOptions.concurrency)\(modeTag)")

        let batch = await engine.signInAll(
            accounts: targets,
            ticket: ticket,
            options: runOptions,
            onProgress: { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self, var current = self.progress else { return }
                    current.completed += 1
                    if result.ok || result.state == .DRY_RUN {
                        current.succeeded += 1
                    } else {
                        current.failed += 1
                    }
                    self.progress = current
                }
            }
        )

        report = batch
        cachedExportJSON = encodeZeroCredentialExport(for: batch)

        // 安全会话回写：仅更新仍在账号池中且确实变更的凭据，绝不复活已删账号，绝不覆写 label/enabled
        if !runOptions.dryRun && !batch.sessionUpdates.isEmpty {
            let merged = AccountVaultStore.applyingRefreshedCredentials(
                to: accounts,
                updates: batch.sessionUpdates
            )
            if merged.appliedCount > 0 {
                accounts = merged.accounts
                vaultStore.save(accounts)
                appendLog("已安全回写 \(merged.appliedCount) 个账号的新会话凭据")
            }
        }

        // 将 AUTH_REQUIRED 结果温和标记到账号 note，便于用户在账号舱快速续期
        if !runOptions.dryRun {
            var noteChanged = false
            for res in batch.results {
                if res.state == .AUTH_REQUIRED {
                    updateAccountInPlace(id: res.accountId) { acc in
                        acc.note = "签到返回鉴权失败，建议重新登录"
                        noteChanged = true
                    }
                } else if res.ok {
                    updateAccountInPlace(id: res.accountId) { acc in
                        acc.lastOkAt = TimeUtil.nowMillis()
                        if !acc.note.isEmpty {
                            acc.note = ""
                        }
                        noteChanged = true
                    }
                }
            }
            if noteChanged {
                vaultStore.save(accounts)
            }
        }

        appendLog("完成：成功 \(batch.successCount) / 演练 \(batch.dryRunCount) / 失败 \(batch.failedCount) · 耗时 \(batch.elapsedMs) ms")
        for result in batch.results {
            let strategy = result.strategy.map { " @\($0)" } ?? ""
            appendLog("· \(result.label)：\(result.state.displayName)\(strategy) — \(result.message)")
        }

        running = false
        progress = nil
        LiquidHaptics.notify(batch.failedCount == 0 ? .success : .warning)
        if switchToTelemetry {
            activeTab = .telemetry
        }
    }

    // MARK: 登录桥接

    func loginStart(edition: Edition) async -> LoginPoll {
        await login.start(edition: edition)
    }

    func loginPoll(edition: Edition, loginToken: String) async -> LoginPoll {
        await login.poll(edition: edition, loginToken: loginToken)
    }

    func loginSubmitCode(edition: Edition, loginToken: String, code: String) async -> LoginPoll {
        await login.submitCode(edition: edition, loginToken: loginToken, code: code)
    }

    @discardableResult
    func adoptLogin(_ poll: LoginPoll) -> Bool {
        guard let account = poll.account, account.hasCredential else { return false }
        upsert(account)
        appendLog("扫码登录成功，已入库：\(account.label)")
        return true
    }

    // MARK: 零凭据导出（缓存按需生成）

    func encodeZeroCredentialExport(for batch: SignBatchReport) -> String {
        let export = SignExport(
            exportedAt: TimeUtil.nowMillis(),
            profileName: profileStore.profile.name,
            profileVersion: profileStore.profile.version,
            ticket: batch.ticket,
            results: batch.results
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(export),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    // MARK: 日志与提示

    func appendLog(_ line: String) {
        let stamp = TimeUtil.format(millis: TimeUtil.nowMillis())
        log.append("[\(stamp)] \(line)")
        if log.count > 300 {
            log.removeFirst(log.count - 300)
        }
    }

    func dismissNotice() {
        notice = nil
    }
}
