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
    @Published private(set) var history: [CheckInHistoryEntry]
    @Published var verifyingAccountIds: Set<String>
    @Published var toastMessage: String?

    @Published private(set) var isScannerSessionActive: Bool = false
    @Published private(set) var scannerSessionSucceededAccountIds: Set<String> = []
    @Published private(set) var scannerSessionTargetAccountIds: Set<String> = []
    @Published private(set) var scannerOverlayNotification: ScannerOverlayNotification? = nil
    @Published private(set) var activeBatchSkippedCount: Int = 0

    let profile: ProtocolProfile
    let phoneLoginClient: PhoneLoginClient

    private let vault: any AccountVaulting
    private let historyStore: any CheckInHistoryStoring
    private let client: RainCheckClient
    private let orchestrator: CheckInOrchestrator
    private var checkInTask: Task<Void, Never>?
    private var activeCheckInRunId: UUID?
    private var activeScannerSessionId: UUID?
    private var activeRunScannerSessionId: UUID?
    private var activeRunTicket: QrTicket?
    private var activeRunDryRun: Bool = false
    private var activeRunPartialResults: [SignResult] = []
    private var toastTask: Task<Void, Never>?
    private var lastBatchWasDryRun: Bool

    private static let maxHistoryEntries = 200

    init(
        vault: any AccountVaulting = KeychainVault(),
        historyStore: (any CheckInHistoryStoring)? = nil,
        profile: ProtocolProfile = ProtocolCatalog.loadBundled(),
        session: URLSession = .shared,
        phoneLoginClient: PhoneLoginClient? = nil
    ) {
        self.vault = vault
        let resolvedHistoryStore: any CheckInHistoryStoring = historyStore
            ?? (vault is InMemoryAccountVault ? InMemoryCheckInHistoryStore() : FileCheckInHistoryStore())
        self.historyStore = resolvedHistoryStore
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
        self.history = Array(resolvedHistoryStore.load().prefix(Self.maxHistoryEntries))
        self.verifyingAccountIds = []
        self.toastMessage = nil
        self.isScannerSessionActive = false
        self.scannerSessionSucceededAccountIds = []
        self.scannerSessionTargetAccountIds = []
        self.scannerOverlayNotification = nil
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

    /// 校验当前票据域名是否受信任（无 URL 视为安全；有 URL 时须通过白名单、官方 `app://yuketang/` 深链或匹配已有账号同源校验）。
    func isCurrentTicketHostTrusted() -> Bool {
        guard let ticket = currentTicket else { return true }
        return isTicketHostTrusted(ticket)
    }

    /// 校验任意票据域名是否受信任，不依赖修改 `currentTicket`。
    func isTicketHostTrusted(_ ticket: QrTicket) -> Bool {
        guard let url = ticket.url, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return true
        }
        let lowerUrl = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowerUrl.hasPrefix("app://yuketang/") {
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

    // MARK: - Continuous Scanner Session

    var scannerSessionTotalCount: Int {
        selectedEnabledAccounts.count
    }

    var scannerSessionSucceededCount: Int {
        selectedEnabledAccounts.filter { scannerSessionSucceededAccountIds.contains($0.id) }.count
    }

    var scannerSessionRemainingAccounts: [Account] {
        selectedEnabledAccounts.filter { !scannerSessionSucceededAccountIds.contains($0.id) }
    }

    var scannerSessionSucceededLabels: [String] {
        selectedEnabledAccounts
            .filter { scannerSessionSucceededAccountIds.contains($0.id) }
            .map(\.label)
    }

    /// 进入持续扫码会话：重置本轮已成功自动禁用名单（绝不修改账号全局启停与勾选状态）。
    func beginScannerSession() {
        activeScannerSessionId = UUID()
        scannerSessionSucceededAccountIds = []
        scannerSessionTargetAccountIds = Set(selectedEnabledAccounts.map(\.id))
        scannerOverlayNotification = nil
        activeBatchSkippedCount = 0
        isScannerSessionActive = true
    }

    /// 退出持续扫码会话：清空会话级已成功禁用名单与悬浮通知，下次进入扫码界面自动重新开始。
    func endScannerSession() {
        isScannerSessionActive = false
        activeScannerSessionId = nil
        scannerSessionSucceededAccountIds = []
        scannerSessionTargetAccountIds = []
        scannerOverlayNotification = nil
        activeBatchSkippedCount = 0
    }

    func dismissScannerOverlayNotification() {
        scannerOverlayNotification = nil
    }

    /// 在扫码页顶部点击状态胶囊时，按当前会话状态重新展示悬浮汇总（已成功自动禁用名单与待签余量）。
    func presentScannerSessionStatusNotification() {
        guard isScannerSessionActive, !isCheckingIn else { return }
        let total = scannerSessionTotalCount
        guard total > 0 else { return }
        let succeeded = scannerSessionSucceededCount
        let remaining = scannerSessionRemainingAccounts.count
        let succeededNames = scannerSessionSucceededLabels

        if remaining == 0 {
            scannerOverlayNotification = ScannerOverlayNotification(
                kind: .success,
                title: "本轮 \(total) 个账号已全部签到成功",
                detail: "已成功账号本轮已自动禁用提交，退出后下次进入扫码将重置",
                succeededLabels: succeededNames,
                failedSummaries: [],
                sessionSucceededCount: succeeded,
                sessionTotalCount: total
            )
        } else if succeeded > 0 {
            scannerOverlayNotification = ScannerOverlayNotification(
                kind: .info,
                title: "本轮已成功 \(succeeded)/\(total) 个账号",
                detail: "以上账号本轮已自动禁用提交，继续扫码仅提交剩余 \(remaining) 个账号",
                succeededLabels: succeededNames,
                failedSummaries: [],
                sessionSucceededCount: succeeded,
                sessionTotalCount: total
            )
        } else {
            scannerOverlayNotification = ScannerOverlayNotification(
                kind: .info,
                title: "本轮待签 \(total) 个账号",
                detail: "对准签到二维码即可自动提交，成功账号将在本轮自动禁用重复提交",
                succeededLabels: [],
                failedSummaries: [],
                sessionSucceededCount: 0,
                sessionTotalCount: total
            )
        }
    }

    /// 持续扫码页回调：
    /// - 留在扫码界面不退出；
    /// - 进行中批次期间静默忽略重复帧；
    /// - 严格拦截空码、登录码、未识别码与非受信任域名（零网络请求）；
    /// - 仅向本轮尚未成功的已选账号发起签到；若全部已成功则零请求并弹出悬浮提示；
    /// - 本轮已有成功批次时，拦截的无效码或全员已成功后的后续码不覆盖 `currentTicket`，保证退出扫码后首页结果条不消失。
    func handleContinuousScannerQr(_ raw: String) {
        guard !isCheckingIn else { return }

        let ticket = QrCodeParser.parse(raw, profile: profile)
        let preserveExistingTicketOnNoOp = !scannerSessionSucceededAccountIds.isEmpty && lastBatchTicket != nil

        guard !ticket.raw.isEmpty else {
            scannerOverlayNotification = ScannerOverlayNotification(
                kind: .warning,
                title: "未检测到有效二维码内容",
                detail: "请调整镜头距离或对准清晰完整的雨课堂签到二维码",
                sessionSucceededCount: scannerSessionSucceededCount,
                sessionTotalCount: scannerSessionTotalCount
            )
            return
        }

        switch ticket.kind {
        case .login:
            if !preserveExistingTicketOnNoOp {
                currentTicket = ticket
            }
            scannerOverlayNotification = ScannerOverlayNotification(
                kind: .warning,
                title: "这是登录二维码，非课堂签到码",
                detail: "未发起签到请求；如需添加账号请前往「账号」页登录",
                sessionSucceededCount: scannerSessionSucceededCount,
                sessionTotalCount: scannerSessionTotalCount
            )
            return
        case .unknown:
            if !preserveExistingTicketOnNoOp {
                currentTicket = ticket
            }
            scannerOverlayNotification = ScannerOverlayNotification(
                kind: .warning,
                title: "未识别为标准签到二维码",
                detail: "未发起签到请求，请对准雨课堂动态签到码或课堂二维码",
                sessionSucceededCount: scannerSessionSucceededCount,
                sessionTotalCount: scannerSessionTotalCount
            )
            return
        case .dynamicCheckin, .lessonOnly:
            break
        }

        if !isTicketHostTrusted(ticket) {
            if !preserveExistingTicketOnNoOp {
                currentTicket = ticket
            }
            let hostText = ticket.host ?? "未知域名"
            scannerOverlayNotification = ScannerOverlayNotification(
                kind: .warning,
                title: "识别到非受信任域名",
                detail: "已拦截 \(hostText)，未发起网络请求；请确认二维码来源",
                sessionSucceededCount: scannerSessionSucceededCount,
                sessionTotalCount: scannerSessionTotalCount
            )
            return
        }

        let selected = selectedEnabledAccounts
        guard !selected.isEmpty else {
            if !preserveExistingTicketOnNoOp {
                currentTicket = ticket
            }
            scannerOverlayNotification = ScannerOverlayNotification(
                kind: .warning,
                title: "请先选择至少一个已启用账号",
                detail: "关闭扫码页并在签到页勾选账号后再试",
                sessionSucceededCount: 0,
                sessionTotalCount: 0
            )
            return
        }

        if !isScannerSessionActive {
            isScannerSessionActive = true
        }
        if activeScannerSessionId == nil {
            activeScannerSessionId = UUID()
        }
        if scannerSessionTargetAccountIds.isEmpty {
            scannerSessionTargetAccountIds = Set(selected.map(\.id))
        }

        let remaining = scannerSessionRemainingAccounts
        if remaining.isEmpty {
            if lastBatchTicket == nil {
                currentTicket = ticket
            }
            scannerOverlayNotification = ScannerOverlayNotification(
                kind: .success,
                title: "本轮所选账号已全部签到成功",
                detail: "已成功账号本轮已自动禁用提交，重复扫码不会再发送请求",
                succeededLabels: scannerSessionSucceededLabels,
                failedSummaries: [],
                sessionSucceededCount: scannerSessionSucceededCount,
                sessionTotalCount: scannerSessionTotalCount
            )
            return
        }

        currentTicket = ticket
        lastBatchTicket = ticket
        lastBatchWasDryRun = dryRun
        let skippedBeforeRun = dryRun ? 0 : max(0, selected.count - remaining.count)
        runCheckIn(
            targets: remaining,
            ticket: ticket,
            dryRun: dryRun,
            replacingResults: scannerSessionSucceededAccountIds.isEmpty,
            fromScannerSession: true,
            skippedCount: skippedBeforeRun
        )
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
        runCheckIn(
            targets: targets,
            ticket: ticket,
            dryRun: dryRun,
            replacingResults: true,
            fromScannerSession: false
        )
    }

    func cancelCheckIn() {
        let partialResults = activeRunPartialResults
        let partialTicket = activeRunTicket
        let partialDryRun = activeRunDryRun
        let wasActiveScannerRun = activeRunScannerSessionId != nil
            && activeRunScannerSessionId == activeScannerSessionId
            && isScannerSessionActive

        checkInTask?.cancel()
        checkInTask = nil
        activeCheckInRunId = nil
        activeBatchSkippedCount = 0
        activeRunPartialResults = []
        activeRunTicket = nil
        activeRunDryRun = false
        activeRunScannerSessionId = nil

        if isCheckingIn {
            isCheckingIn = false
            if let ticket = partialTicket, !partialResults.isEmpty {
                appendHistoryEntry(
                    ticket: ticket,
                    dryRun: partialDryRun,
                    results: partialResults
                )
            }
            if wasActiveScannerRun || isScannerSessionActive {
                let completedSucceeded = partialResults
                    .filter { $0.state.isSuccessLike }
                    .map(\.accountLabel)
                scannerOverlayNotification = ScannerOverlayNotification(
                    kind: .info,
                    title: "已取消本次签到",
                    detail: partialResults.isEmpty
                        ? "可继续对准二维码重新扫描"
                        : "已保留已完成的 \(partialResults.count) 条结果至历史记录，可继续扫码",
                    succeededLabels: completedSucceeded,
                    sessionSucceededCount: scannerSessionSucceededCount,
                    sessionTotalCount: scannerSessionTotalCount
                )
            } else {
                showToast("已取消签到")
            }
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
        runCheckIn(
            targets: targets,
            ticket: ticket,
            dryRun: false,
            replacingResults: false,
            fromScannerSession: false
        )
    }

    private func runCheckIn(
        targets: [Account],
        ticket: QrTicket,
        dryRun: Bool,
        replacingResults: Bool,
        fromScannerSession: Bool = false,
        skippedCount: Int = 0
    ) {
        checkInTask?.cancel()
        let runId = UUID()
        let capturedScannerSessionId = fromScannerSession ? activeScannerSessionId : nil
        activeCheckInRunId = runId
        activeRunScannerSessionId = capturedScannerSessionId
        activeRunTicket = ticket
        activeRunDryRun = dryRun
        activeRunPartialResults = []
        activeBatchSkippedCount = max(0, skippedCount)
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
                        self.upsertActiveRunPartialResult(partial)
                        self.mergeRefreshedAccountIfNeeded(
                            from: partial,
                            snapshot: snapshotById[partial.accountId]
                        )
                        if let sessionId = capturedScannerSessionId,
                           !capturedDryRun,
                           partial.state.isSuccessLike,
                           self.isScannerSessionActive,
                           self.activeScannerSessionId == sessionId {
                            self.scannerSessionSucceededAccountIds.insert(partial.accountId)
                        }
                    }
                }
            )

            guard let self, self.activeCheckInRunId == runId else { return }
            let matchesCurrentScannerSession = capturedScannerSessionId != nil
                && self.isScannerSessionActive
                && self.activeScannerSessionId == capturedScannerSessionId

            if !Task.isCancelled {
                for result in batchResults {
                    self.upsertResult(result)
                    self.mergeRefreshedAccountIfNeeded(
                        from: result,
                        snapshot: snapshotById[result.accountId]
                    )
                    if matchesCurrentScannerSession && !capturedDryRun && result.state.isSuccessLike {
                        self.scannerSessionSucceededAccountIds.insert(result.accountId)
                    }
                }
                self.checkInCompletedCount = batchResults.count

                if !batchResults.isEmpty {
                    self.appendHistoryEntry(
                        ticket: ticket,
                        dryRun: capturedDryRun,
                        results: batchResults
                    )
                }

                if matchesCurrentScannerSession {
                    self.scannerOverlayNotification = self.makeScannerOverlayNotification(
                        batchResults: batchResults,
                        dryRun: capturedDryRun
                    )
                } else {
                    let okCount = batchResults.filter { $0.state.isSuccessLike }.count
                    if capturedDryRun {
                        self.showToast("演练完成：已模拟 \(batchResults.count) 个账号，未发起网络请求")
                    } else if okCount < batchResults.count,
                              let firstFailed = batchResults.first(where: { $0.state.isFailureLike }) {
                        self.showToast(
                            "签到失败（\(okCount)/\(batchResults.count)）：\(firstFailed.diagnosticReason)",
                            durationSeconds: 4.5
                        )
                    } else {
                        self.showToast("签到完成：成功 \(okCount) / \(batchResults.count)")
                    }
                }
            }
            self.isCheckingIn = false
            self.checkInTask = nil
            self.activeCheckInRunId = nil
            self.activeBatchSkippedCount = 0
            self.activeRunPartialResults = []
            self.activeRunTicket = nil
            self.activeRunDryRun = false
            self.activeRunScannerSessionId = nil
        }
    }

    private func makeScannerOverlayNotification(
        batchResults: [SignResult],
        dryRun: Bool
    ) -> ScannerOverlayNotification {
        let totalSession = scannerSessionTotalCount
        let succeededSession = scannerSessionSucceededCount
        let remainingCount = scannerSessionRemainingAccounts.count

        if dryRun {
            return ScannerOverlayNotification(
                kind: .info,
                title: "演练完成（已模拟 \(batchResults.count) 个账号）",
                detail: "演练模式未发起网络请求，账号未计入本轮成功禁用名单",
                succeededLabels: batchResults.map(\.accountLabel),
                failedSummaries: [],
                sessionSucceededCount: succeededSession,
                sessionTotalCount: totalSession
            )
        }

        let newlySucceeded = batchResults.filter { $0.state.isSuccessLike }
        let failed = batchResults.filter { $0.state.isFailureLike }
        let newlySucceededLabels = newlySucceeded.map(\.accountLabel)
        let failedSummaries = failed.map { "\($0.accountLabel)：\($0.diagnosticReason)" }

        if !newlySucceeded.isEmpty && failed.isEmpty {
            let title: String
            let detail: String
            if remainingCount == 0 && totalSession > 0 {
                title = "本轮 \(totalSession) 个账号已全部签到成功"
                detail = "已成功账号本轮已自动禁用提交，继续扫码不会重复发送请求"
            } else {
                title = "本次 \(newlySucceeded.count) 个账号签到成功"
                detail = "已成功账号本轮已自动禁用提交，可继续扫描二维码"
            }
            return ScannerOverlayNotification(
                kind: .success,
                title: title,
                detail: detail,
                succeededLabels: newlySucceededLabels,
                failedSummaries: [],
                sessionSucceededCount: succeededSession,
                sessionTotalCount: totalSession
            )
        }

        if !newlySucceeded.isEmpty && !failed.isEmpty {
            return ScannerOverlayNotification(
                kind: .partial,
                title: "本次成功 \(newlySucceeded.count) 个 · 失败 \(failed.count) 个",
                detail: "已成功账号本轮已自动禁用提交，再次扫码仅提交剩余 \(remainingCount) 个失败账号",
                succeededLabels: newlySucceededLabels,
                failedSummaries: failedSummaries,
                sessionSucceededCount: succeededSession,
                sessionTotalCount: totalSession
            )
        }

        let title = failed.isEmpty
            ? "本次未产生新的签到结果"
            : "本次 \(failed.count) 个账号签到失败"
        let detail: String
        if succeededSession > 0 {
            detail = "本轮已有 \(succeededSession)/\(totalSession) 个成功账号已自动跳过，可继续扫码重试剩余 \(remainingCount) 个"
        } else {
            detail = "请对准最新动态签到码重试，或关闭后在记录页查看完整日志"
        }
        return ScannerOverlayNotification(
            kind: .failure,
            title: title,
            detail: detail,
            succeededLabels: [],
            failedSummaries: failedSummaries,
            sessionSucceededCount: succeededSession,
            sessionTotalCount: totalSession
        )
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
        scannerSessionSucceededAccountIds.remove(id)
        scannerSessionTargetAccountIds.remove(id)
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

    // MARK: - Results, Persistent History & Sanitized Export

    func clearResults() {
        results = []
        lastBatchTicket = nil
        lastBatchWasDryRun = false
    }

    func deleteResult(id: String) {
        let before = results.count
        results.removeAll { $0.id == id }
        guard results.count != before else { return }
        if results.isEmpty {
            lastBatchTicket = nil
            lastBatchWasDryRun = false
        }
        showToast("已删除该条记录")
    }

    func deleteHistoryEntry(id: String) {
        let before = history.count
        history.removeAll { $0.id == id }
        guard history.count != before else { return }
        historyStore.save(history)
        showToast("已删除历史记录")
    }

    func deleteHistoryEntries(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let before = history.count
        history.removeAll { ids.contains($0.id) }
        guard history.count != before else { return }
        historyStore.save(history)
        showToast("已删除 \(before - history.count) 条历史记录")
    }

    func clearHistory() {
        guard !history.isEmpty else { return }
        history = []
        historyStore.save([])
        showToast("已清空历史记录")
    }

    private func appendHistoryEntry(
        ticket: QrTicket,
        dryRun: Bool,
        results: [SignResult]
    ) {
        guard !results.isEmpty else { return }
        let entry = CheckInHistoryEntry.from(
            ticket: ticket,
            dryRun: dryRun,
            results: results
        )
        history.insert(entry, at: 0)
        if history.count > Self.maxHistoryEntries {
            history = Array(history.prefix(Self.maxHistoryEntries))
        }
        historyStore.save(history)
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

    func exportHistoryEntryReportData(_ entry: CheckInHistoryEntry) throws -> Data {
        let formatter = ISO8601DateFormatter()
        let report = HistoryEntryExportReport(
            exportedAt: formatter.string(from: Date()),
            entry: entry
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(report)
    }

    func exportHistoryEntryReportURL(_ entry: CheckInHistoryEntry) throws -> URL {
        let data = try exportHistoryEntryReportData(entry)
        let filteredId = String(entry.id.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }.prefix(8))
        let safeIdPrefix = filteredId.isEmpty ? "entry" : filteredId
        let filename = "raincheck-history-\(entry.createdAtMs)-\(safeIdPrefix).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    func exportAllHistoryReportData() throws -> Data {
        let formatter = ISO8601DateFormatter()
        let report = HistoryExportReport(
            exportedAt: formatter.string(from: Date()),
            totalEntries: history.count,
            entries: history
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(report)
    }

    func exportAllHistoryReportURL() throws -> URL {
        let data = try exportAllHistoryReportData()
        let filename = "raincheck-history-all-\(RainCheckTime.nowMillis()).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    // MARK: - Toast

    func showToast(_ message: String, durationSeconds: Double = 2.8) {
        toastTask?.cancel()
        toastMessage = message
        let nanos = UInt64(max(1.0, durationSeconds) * 1_000_000_000)
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
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

    private func upsertActiveRunPartialResult(_ result: SignResult) {
        if let index = activeRunPartialResults.firstIndex(where: { $0.accountId == result.accountId }) {
            activeRunPartialResults[index] = result
        } else {
            activeRunPartialResults.append(result)
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
