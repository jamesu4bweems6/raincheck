import Combine
import Foundation

/// 全局应用状态容器（严格 `@MainActor` 隔离，统一驱动签到、账号池与记录导出）。
@MainActor
final class AppStore: ObservableObject {
    @Published var accounts: [Account]
    @Published var selectedAccountIds: Set<String>
    @Published var currentTicket: QrTicket?
    @Published private(set) var lastBatchTicket: QrTicket?
    @Published var dryRun: Bool
    @Published var isCheckingIn: Bool
    @Published var checkInCompletedCount: Int
    @Published var checkInTotalCount: Int
    @Published var results: [SignResult]
    @Published var verifyingAccountIds: Set<String>
    @Published var toastMessage: String?

    let profile: ProtocolProfile
    let phoneLoginClient: PhoneLoginClient

    private let vault: any AccountVaulting
    private let client: RainCheckClient
    private let orchestrator: CheckInOrchestrator
    private var checkInTask: Task<Void, Never>?
    private var activeCheckInRunId: UUID?
    private var toastTask: Task<Void, Never>?
    private var lastBatchWasDryRun: Bool

    init(
        vault: any AccountVaulting = KeychainVault(),
        profile: ProtocolProfile = ProtocolCatalog.loadBundled(),
        session: URLSession = .shared,
        phoneLoginClient: PhoneLoginClient? = nil
    ) {
        self.vault = vault
        self.profile = profile

        let networkClient = RainCheckClient(session: session, profile: profile)
        self.client = networkClient
        self.orchestrator = CheckInOrchestrator(client: networkClient, profile: profile)
        self.phoneLoginClient = phoneLoginClient ?? PhoneLoginClient(session: session, profile: profile)

        let loadedAccounts = vault.load()
        self.accounts = loadedAccounts
        self.selectedAccountIds = Set(loadedAccounts.filter(\.enabled).map(\.id))
        self.currentTicket = nil
        self.lastBatchTicket = nil
        self.lastBatchWasDryRun = false
        self.dryRun = false
        self.isCheckingIn = false
        self.checkInCompletedCount = 0
        self.checkInTotalCount = 0
        self.results = []
        self.verifyingAccountIds = []
        self.toastMessage = nil
    }

    // MARK: - Ticket Handling

    /// 解析扫描或粘贴的二维码文本。
    /// 当 `autoStartCheckIn` 为 `true` 时，对受信任的标准签到码（动态码或课堂码）在已选账号非空且无进行中批次时立即自动触发签到；
    /// 登录码、未知码、非受信任域名或默认 `false` 调用仅更新当前票据并提示，不自动发起签到请求。
    func applyQrInput(_ raw: String, autoStartCheckIn: Bool = false) {
        let ticket = QrCodeParser.parse(raw, profile: profile)
        guard !ticket.raw.isEmpty else {
            showToast("未检测到有效二维码内容")
            return
        }
        currentTicket = ticket

        guard autoStartCheckIn else {
            switch ticket.kind {
            case .dynamicCheckin:
                showToast("已识别动态签到码")
            case .lessonOnly:
                showToast("已识别课堂签到目标")
            case .login:
                showToast("这是登录二维码而非课堂签到码；如需添加账号请前往「账号」页使用手机号验证码登录或手动导入")
            case .unknown:
                showToast("未识别为标准签到码")
            }
            return
        }

        switch ticket.kind {
        case .login:
            showToast("这是登录二维码而非课堂签到码；如需添加账号请前往「账号」页使用手机号验证码登录或手动导入")
        case .unknown:
            showToast("未识别为标准签到码，已暂停自动签到")
        case .dynamicCheckin, .lessonOnly:
            if isCheckingIn {
                showToast("当前正在签到中，已更新二维码，请稍后或取消后重试")
                return
            }
            let targets = selectedEnabledAccounts
            if targets.isEmpty {
                showToast("已识别签到码，请先选择至少一个已启用账号")
                return
            }
            if !isCurrentTicketHostTrusted() {
                showToast("识别到非受信任域名，已暂停自动签到，请核对后再手动执行")
                return
            }
            startCheckIn()
            showToast(
                dryRun
                    ? "已识别签到码，正在为 \(targets.count) 个账号演练签到"
                    : "已识别签到码，正在为 \(targets.count) 个账号自动签到"
            )
        }
    }

    func clearTicket() {
        currentTicket = nil
    }

    /// 校验当前票据域名是否受信任（无 URL 视为安全；有 URL 时须通过白名单或匹配已有账号同源校验）。
    func isCurrentTicketHostTrusted() -> Bool {
        guard let ticket = currentTicket else { return true }
        guard let url = ticket.url, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return true
        }
        if QrCodeParser.validateQrUrl(url, account: nil, profile: profile) {
            return true
        }
        for account in accounts where account.enabled {
            if QrCodeParser.validateQrUrl(url, account: account, profile: profile) {
                return true
            }
        }
        return false
    }

    // MARK: - Selection

    var selectedEnabledAccounts: [Account] {
        accounts.filter { $0.enabled && selectedAccountIds.contains($0.id) }
    }

    func toggleSelection(accountId: String) {
        if selectedAccountIds.contains(accountId) {
            selectedAccountIds.remove(accountId)
        } else if let account = accounts.first(where: { $0.id == accountId }), account.enabled {
            selectedAccountIds.insert(accountId)
        }
    }

    func toggleSelectAllEnabled() {
        let enabledIds = Set(accounts.filter(\.enabled).map(\.id))
        guard !enabledIds.isEmpty else {
            selectedAccountIds.removeAll()
            return
        }
        if enabledIds.isSubset(of: selectedAccountIds) {
            selectedAccountIds.subtract(enabledIds)
        } else {
            selectedAccountIds = enabledIds
        }
    }

    // MARK: - Check-In Execution

    func startCheckIn() {
        guard !isCheckingIn else { return }
        guard let ticket = currentTicket else {
            showToast("请先扫描或粘贴签到二维码")
            return
        }
        if ticket.kind == .login {
            showToast("这是登录二维码而非课堂签到码；如需添加账号请前往「账号」页使用手机号验证码登录或手动导入")
            return
        }

        let targets = selectedEnabledAccounts
        guard !targets.isEmpty else {
            showToast("请至少选择一个已启用账号")
            return
        }

        lastBatchTicket = ticket
        lastBatchWasDryRun = dryRun
        runCheckIn(targets: targets, ticket: ticket, dryRun: dryRun, replacingResults: true)
    }

    func cancelCheckIn() {
        checkInTask?.cancel()
        checkInTask = nil
        activeCheckInRunId = nil
        if isCheckingIn {
            isCheckingIn = false
            showToast("已取消签到")
        }
    }

    func retryFailed() {
        guard !isCheckingIn else { return }
        guard let ticket = lastBatchTicket else {
            showToast("当前没有可重试的签到目标")
            return
        }
        let failedIds = Set(results.filter { $0.state.isFailureLike }.map(\.accountId))
        let targets = accounts.filter { $0.enabled && failedIds.contains($0.id) }
        guard !targets.isEmpty else {
            showToast("没有可重试的失败账号")
            return
        }

        lastBatchWasDryRun = false
        runCheckIn(targets: targets, ticket: ticket, dryRun: false, replacingResults: false)
    }

    private func runCheckIn(
        targets: [Account],
        ticket: QrTicket,
        dryRun: Bool,
        replacingResults: Bool
    ) {
        checkInTask?.cancel()
        let runId = UUID()
        activeCheckInRunId = runId
        isCheckingIn = true
        checkInCompletedCount = 0
        checkInTotalCount = targets.count
        if replacingResults {
            results = []
        }

        let engine = self.orchestrator
        let capturedDryRun = dryRun
        let snapshotById = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0) })

        checkInTask = Task { [weak self] in
            let batchResults = await engine.checkInBatch(
                accounts: targets,
                ticket: ticket,
                dryRun: capturedDryRun,
                maxConcurrency: 4,
                onProgress: { [weak self] partial in
                    Task { @MainActor [weak self] in
                        guard let self, self.activeCheckInRunId == runId else { return }
                        self.checkInCompletedCount += 1
                        self.upsertResult(partial)
                        self.mergeRefreshedAccountIfNeeded(
                            from: partial,
                            snapshot: snapshotById[partial.accountId]
                        )
                    }
                }
            )

            guard let self, self.activeCheckInRunId == runId else { return }
            if !Task.isCancelled {
                for result in batchResults {
                    self.upsertResult(result)
                    self.mergeRefreshedAccountIfNeeded(
                        from: result,
                        snapshot: snapshotById[result.accountId]
                    )
                }
                self.checkInCompletedCount = batchResults.count
                let okCount = batchResults.filter { $0.state.isSuccessLike }.count
                if capturedDryRun {
                    self.showToast("演练完成：已模拟 \(batchResults.count) 个账号，未发起网络请求")
                } else {
                    self.showToast("签到完成：成功 \(okCount) / \(batchResults.count)")
                }
            }
            self.isCheckingIn = false
            self.checkInTask = nil
            self.activeCheckInRunId = nil
        }
    }

    // MARK: - Account Management

    func addOrUpdateAccount(_ account: Account) throws {
        try vault.upsert(account)

        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
            if !account.enabled {
                selectedAccountIds.remove(account.id)
            }
        } else {
            accounts.append(account)
            if account.enabled {
                selectedAccountIds.insert(account.id)
            }
        }
        showToast("已保存账号：\(account.label)")
    }

    func deleteAccount(id: String) {
        accounts.removeAll { $0.id == id }
        selectedAccountIds.remove(id)
        verifyingAccountIds.remove(id)
        try? vault.remove(id: id)
        showToast("已删除账号")
    }

    func toggleAccountEnabled(id: String) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].enabled.toggle()
        if accounts[index].enabled {
            selectedAccountIds.insert(id)
        } else {
            selectedAccountIds.remove(id)
        }
        try? vault.upsert(accounts[index])
    }

    func verifyAccount(id: String) async {
        guard let snapshot = accounts.first(where: { $0.id == id }) else { return }
        guard !verifyingAccountIds.contains(id) else { return }
        guard snapshot.hasCredential else {
            showToast("账号未配置凭据")
            return
        }

        verifyingAccountIds.insert(id)
        defer { verifyingAccountIds.remove(id) }

        do {
            let snapshotHadBearer = !(snapshot.bearer?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            let verified = try await client.fetchMe(account: snapshot)
            // 安全合并：只更新仍存在的账号的凭据 / userId / lastOkAt，避免覆盖并发删除或编辑
            if let refreshed = verified.refreshedAccount {
                let refreshedHasBearer = !(refreshed.bearer?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                let staleBearerToClear = (snapshotHadBearer && !refreshedHasBearer) ? snapshot.bearer : nil
                applyRefreshedFields(
                    from: refreshed,
                    verifiedName: verified.name,
                    clearingStaleBearer: staleBearerToClear
                )
            }
            let displayName = verified.name ?? accounts.first(where: { $0.id == id })?.label ?? snapshot.label
            showToast("验证通过：\(displayName)")
        } catch {
            showToast("验证失败：\(error.localizedDescription)")
        }
    }

    // MARK: - Results & Sanitized Export

    func clearResults() {
        results = []
        lastBatchTicket = nil
        lastBatchWasDryRun = false
    }

    /// 导出脱敏 JSON 报告（`SignResult.CodingKeys` 严格排除所有凭据与 `refreshedAccount`）。
    func exportSanitizedReportData() throws -> Data {
        let formatter = ISO8601DateFormatter()
        let report = ExportReport(
            exportedAt: formatter.string(from: Date()),
            ticketSummary: (lastBatchTicket ?? currentTicket)?.summary(),
            dryRun: lastBatchTicket != nil ? lastBatchWasDryRun : dryRun,
            results: results
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(report)
    }

    func exportSanitizedReportURL() throws -> URL {
        let data = try exportSanitizedReportData()
        let filename = "raincheck-report-\(RainCheckTime.nowMillis()).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    // MARK: - Toast

    func showToast(_ message: String) {
        toastTask?.cancel()
        toastMessage = message
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            guard !Task.isCancelled else { return }
            self?.toastMessage = nil
        }
    }

    // MARK: - Safe Merge Helpers

    private func upsertResult(_ result: SignResult) {
        if let index = results.firstIndex(where: { $0.accountId == result.accountId }) {
            results[index] = result
        } else {
            results.append(result)
        }
    }

    private func mergeRefreshedAccountIfNeeded(from result: SignResult, snapshot: Account? = nil) {
        if let refreshed = result.refreshedAccount {
            let snapshotHadBearer = !(snapshot?.bearer?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            let refreshedHasBearer = !(refreshed.bearer?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            let staleBearerToClear = (snapshotHadBearer && !refreshedHasBearer) ? snapshot?.bearer : nil
            applyRefreshedFields(
                from: refreshed,
                verifiedName: nil,
                clearingStaleBearer: staleBearerToClear
            )
        }

        if result.state == .success || result.state == .already {
            guard let index = accounts.firstIndex(where: { $0.id == result.accountId }) else {
                return
            }
            if result.timestampMs > (accounts[index].lastOkAt ?? 0) {
                accounts[index].lastOkAt = result.timestampMs
                try? vault.upsert(accounts[index])
            }
        }
    }

    /// 安全回填：只对当前仍存在于账号池中的账号合并凭据、`userId` 与 `lastOkAt`，
    /// 绝不复活并发删除的账号，也不覆盖用户并发修改的备注、自定义标签或启停开关。
    private func applyRefreshedFields(
        from refreshed: Account,
        verifiedName: String?,
        clearingStaleBearer: String? = nil
    ) {
        guard let index = accounts.firstIndex(where: { $0.id == refreshed.id }) else {
            return
        }
        var current = accounts[index]
        var changed = false

        if let bearer = refreshed.bearer,
           !bearer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           bearer != current.bearer {
            current.bearer = bearer
            changed = true
        } else if let staleBearer = clearingStaleBearer,
                  current.bearer == staleBearer,
                  !(current.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            current.bearer = nil
            changed = true
        }
        if let sessionId = refreshed.sessionId,
           !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           sessionId != current.sessionId {
            current.sessionId = sessionId
            changed = true
        }
        if let csrfToken = refreshed.csrfToken,
           !csrfToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           csrfToken != current.csrfToken {
            current.csrfToken = csrfToken
            changed = true
        }
        if let userId = refreshed.userId,
           !userId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           userId != current.userId {
            current.userId = userId
            changed = true
        }
        if let verifiedName {
            let trimmedName = verifiedName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedName.isEmpty && Account.isPlaceholderLabel(current.label) && current.label != trimmedName {
                current.label = trimmedName
                changed = true
            }
        }
        if let okAt = refreshed.lastOkAt, okAt > (current.lastOkAt ?? 0) {
            current.lastOkAt = okAt
            changed = true
        }

        if changed {
            accounts[index] = current
            try? vault.upsert(current)
        }
    }
}
