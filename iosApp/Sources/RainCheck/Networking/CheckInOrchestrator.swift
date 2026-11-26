import Dispatch
import Foundation

/// 一次签到推断得到的课堂上下文。
struct LessonContext: Hashable, Sendable {
    let lessonId: String
    let classroomId: String?
    let name: String?
}

/// 多账号多策略签到编排引擎（优先执行 IPA 1.3.6 官方两步扫码签到，保留完整兜底策略与安全护栏）。
final class CheckInOrchestrator: Sendable {
    static let appScanStrategyId = "APP_SCAN_CHECKIN"
    static let appScanWebStrategyId = "APP_SCAN_CHECKIN_WEB"

    let client: RainCheckClient
    let profile: ProtocolProfile
    let maxAttemptsPerStrategy: Int
    let baseBackoffMs: UInt64
    let staggerMs: UInt64
    let stopWhenQrExpired: Bool

    init(
        client: RainCheckClient,
        profile: ProtocolProfile = ProtocolCatalog.loadBundled(),
        maxAttemptsPerStrategy: Int = 3,
        baseBackoffMs: UInt64 = 800,
        staggerMs: UInt64 = 60,
        stopWhenQrExpired: Bool = true
    ) {
        self.client = client
        self.profile = profile
        self.maxAttemptsPerStrategy = max(1, min(maxAttemptsPerStrategy, 10))
        self.baseBackoffMs = min(baseBackoffMs, 30_000)
        self.staggerMs = min(staggerMs, 10_000)
        self.stopWhenQrExpired = stopWhenQrExpired
    }

    func applicableStrategies(for ticket: QrTicket) -> [StrategySpec] {
        let ordered = profile.orderedStrategies(for: ticket.kind)
        return ordered.filter { spec in
            let satisfiesRequires = spec.requires.allSatisfy { key in
                switch key {
                case "lessonId":
                    return true // 允许运行期由 appScan 或 activeLesson 发现
                case "c":
                    return !(ticket.dynamicCode?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                case "t":
                    return !(ticket.timestamp?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                case "s":
                    return !(ticket.signature?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                default:
                    return !(ticket.params[key]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                }
            }
            guard satisfiesRequires else { return false }
            if isQrUrlStrategy(spec.id) {
                return !(ticket.url?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            }
            return spec.endpoint != nil
        }
    }

    /// 单账号签到：真实二维码优先执行官方 `APP_SCAN_CHECKIN`（零 upfront `discoverActiveLesson` 延迟），
    /// 命中即停，支持会话刷新回填、最佳错误保留、域名不一致诊断与同源安全护栏。
    func checkIn(account: Account, ticket: QrTicket, dryRun: Bool = false) async -> SignResult {
        let startedMs = RainCheckTime.nowMillis()
        var currentAccount = account
        var credentialsRefreshed = false
        var traces: [AttemptTrace] = []

        if !currentAccount.hasCredential {
            return SignResult(
                accountId: currentAccount.id,
                accountLabel: currentAccount.label,
                host: currentAccount.host,
                state: .authExpired,
                message: "账号没有配置 token / sessionid",
                elapsedMs: max(0, RainCheckTime.nowMillis() - startedMs),
                attempts: traces,
                timestampMs: RainCheckTime.nowMillis(),
                refreshedAccount: nil
            )
        }

        if ticket.kind == .login {
            return SignResult(
                accountId: currentAccount.id,
                accountLabel: currentAccount.label,
                host: currentAccount.host,
                state: .notInClass,
                message: "这是登录二维码而非课堂签到码；如需添加账号请前往「账号」页使用手机号验证码登录或手动导入",
                elapsedMs: max(0, RainCheckTime.nowMillis() - startedMs),
                attempts: traces,
                timestampMs: RainCheckTime.nowMillis(),
                refreshedAccount: nil
            )
        }

        let willRunAppScan = shouldRunAppScan(for: ticket)
        let allCandidates = applicableStrategies(for: ticket)
        if !willRunAppScan && allCandidates.isEmpty {
            return SignResult(
                accountId: currentAccount.id,
                accountLabel: currentAccount.label,
                host: currentAccount.host,
                state: .notInClass,
                message: "协议配置没有适用于 \(ticket.kind.rawValue) 的签到策略",
                elapsedMs: max(0, RainCheckTime.nowMillis() - startedMs),
                attempts: traces,
                timestampMs: RainCheckTime.nowMillis(),
                refreshedAccount: nil
            )
        }

        // 严格演练模式：绝对不发起任何网络请求（包含跳过 appScan 与 activeLesson 探测）
        if dryRun {
            if willRunAppScan, let appScanEndpoint = profile.endpoint("appScan") {
                let base = "\(currentAccount.scheme)://\(currentAccount.host)"
                let scanUrl = TemplateRenderer.buildURL(base: base, path: appScanEndpoint.path, query: [:])
                traces.append(
                    AttemptTrace(
                        strategyId: Self.appScanStrategyId,
                        method: appScanEndpoint.method.uppercased(),
                        url: scanUrl,
                        httpStatus: nil,
                        businessCode: nil,
                        message: "演练模式，未发送",
                        elapsedMs: 0
                    )
                )
            }

            let dryContext = LessonContext(
                lessonId: ticket.lessonId ?? "<discover>",
                classroomId: ticket.classroomId,
                name: nil
            )
            for spec in allCandidates {
                let vars = buildVariables(
                    account: currentAccount,
                    context: dryContext,
                    ticket: ticket,
                    spec: spec
                )
                traces.append(
                    simulateDryRun(account: currentAccount, spec: spec, variables: vars, ticket: ticket)
                )
            }
            return SignResult(
                accountId: currentAccount.id,
                accountLabel: currentAccount.label,
                host: currentAccount.host,
                state: .dryRun,
                strategyId: traces.first?.strategyId ?? allCandidates.first?.id,
                httpStatus: nil,
                businessCode: nil,
                message: "演练模式：已模拟 \(traces.count) 条策略，未发起网络请求",
                elapsedMs: max(0, RainCheckTime.nowMillis() - startedMs),
                attempts: traces,
                timestampMs: RainCheckTime.nowMillis(),
                refreshedAccount: nil
            )
        }

        var bestFailure: FailureCandidate?
        var context: LessonContext?

        // Priority #1: 官方雨课堂 1.3.6 两步扫码流程（POST /api/v3/app/scan -> POST /api/v3/lesson/checkin source=21）
        // 在任何 discoverActiveLesson 之前立即执行，为 5~8 秒动态码节省全部前置 RTT
        if willRunAppScan {
            let appScanOutcome = await executeAppScanFlow(
                ticket: ticket,
                startedMs: startedMs,
                account: &currentAccount,
                credentialsRefreshed: &credentialsRefreshed,
                existingTraces: traces
            )
            switch appScanOutcome {
            case .terminal(let result):
                return result
            case .fallback(let discoveredContext, let failure, let appTraces):
                traces.append(contentsOf: appTraces)
                if let discoveredContext {
                    context = discoveredContext
                }
                if let failure {
                    updateBestFailure(&bestFailure, with: failure)
                }
            }
        }

        // 惰性课堂上下文发现：仅在未通过 ticket.lessonId 或 appScan 获得 lessonId、
        // 且后续存在依赖 lessonId 的兜底策略时才调用 activeLesson
        var discoverFailure: DiscoverOutcome?
        if context == nil {
            if let lessonId = ticket.lessonId, !lessonId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                context = LessonContext(lessonId: lessonId, classroomId: ticket.classroomId, name: nil)
            } else if allCandidates.contains(where: { $0.requires.contains("lessonId") }) {
                let outcome = await discoverActiveLesson(
                    account: &currentAccount,
                    credentialsRefreshed: &credentialsRefreshed,
                    ticket: ticket
                )
                switch outcome {
                case .found(let ctx, let discoverTraces):
                    traces.append(contentsOf: discoverTraces)
                    context = ctx
                case .authExpired(let message, let discoverTraces):
                    traces.append(contentsOf: discoverTraces)
                    let lastDiscover = discoverTraces.last
                    return SignResult(
                        accountId: currentAccount.id,
                        accountLabel: currentAccount.label,
                        host: currentAccount.host,
                        state: .authExpired,
                        strategyId: lastDiscover?.strategyId,
                        httpStatus: lastDiscover?.httpStatus,
                        businessCode: lastDiscover?.businessCode,
                        message: appendHostMismatchHintIfNeeded(
                            message: message,
                            account: currentAccount,
                            ticket: ticket
                        ),
                        elapsedMs: max(0, RainCheckTime.nowMillis() - startedMs),
                        attempts: traces,
                        timestampMs: RainCheckTime.nowMillis(),
                        refreshedAccount: credentialsRefreshed ? currentAccount : nil
                    )
                case .networkError(let message, let discoverTraces):
                    traces.append(contentsOf: discoverTraces)
                    discoverFailure = outcome
                    let lastDiscover = discoverTraces.last
                    updateBestFailure(
                        &bestFailure,
                        with: FailureCandidate(
                            priority: 150,
                            state: .networkError,
                            strategyId: lastDiscover?.strategyId ?? "DISCOVER_ACTIVE_LESSON",
                            httpStatus: lastDiscover?.httpStatus,
                            businessCode: lastDiscover?.businessCode,
                            message: message
                        )
                    )
                    context = nil
                case .notFound(let message, let discoverTraces):
                    traces.append(contentsOf: discoverTraces)
                    discoverFailure = outcome
                    let lastDiscover = discoverTraces.last
                    updateBestFailure(
                        &bestFailure,
                        with: FailureCandidate(
                            priority: 150,
                            state: .notInClass,
                            strategyId: lastDiscover?.strategyId ?? "DISCOVER_ACTIVE_LESSON",
                            httpStatus: lastDiscover?.httpStatus,
                            businessCode: lastDiscover?.businessCode,
                            message: message
                        )
                    )
                    context = nil
                }
            }
        }

        // 缺少 lessonId 时，仅保留不依赖 lessonId 且已通过同源/白名单校验的策略
        let candidates: [StrategySpec]
        if context != nil {
            candidates = allCandidates
        } else {
            candidates = allCandidates.filter { spec in
                guard !spec.requires.contains("lessonId") else { return false }
                if isQrUrlStrategy(spec.id) {
                    guard let url = ticket.url else { return false }
                    return QrCodeParser.validateQrUrl(url, account: currentAccount, profile: profile)
                }
                return true
            }
        }

        if candidates.isEmpty {
            if let bestFailure {
                return SignResult(
                    accountId: currentAccount.id,
                    accountLabel: currentAccount.label,
                    host: currentAccount.host,
                    state: bestFailure.state,
                    strategyId: bestFailure.strategyId ?? traces.last?.strategyId,
                    httpStatus: bestFailure.httpStatus,
                    businessCode: bestFailure.businessCode,
                    message: appendHostMismatchHintIfNeeded(
                        message: bestFailure.message,
                        account: currentAccount,
                        ticket: ticket
                    ),
                    elapsedMs: max(0, RainCheckTime.nowMillis() - startedMs),
                    attempts: traces,
                    timestampMs: RainCheckTime.nowMillis(),
                    refreshedAccount: credentialsRefreshed ? currentAccount : nil
                )
            }

            let finalState: SignState
            let finalMessage: String
            let lastStatus: Int?
            let lastBusinessCode: Int?
            switch discoverFailure {
            case .networkError(let msg, let discoverTraces):
                finalState = .networkError
                finalMessage = msg
                lastStatus = discoverTraces.last?.httpStatus
                lastBusinessCode = discoverTraces.last?.businessCode
            case .notFound(let msg, let discoverTraces):
                finalState = .notInClass
                finalMessage = msg
                lastStatus = discoverTraces.last?.httpStatus
                lastBusinessCode = discoverTraces.last?.businessCode
            default:
                finalState = .notInClass
                finalMessage = "无法确定 lessonId，请确认二维码属于进行中的课堂"
                lastStatus = nil
                lastBusinessCode = nil
            }
            return SignResult(
                accountId: currentAccount.id,
                accountLabel: currentAccount.label,
                host: currentAccount.host,
                state: finalState,
                strategyId: traces.last?.strategyId,
                httpStatus: lastStatus,
                businessCode: lastBusinessCode,
                message: appendHostMismatchHintIfNeeded(
                    message: finalMessage,
                    account: currentAccount,
                    ticket: ticket
                ),
                elapsedMs: max(0, RainCheckTime.nowMillis() - startedMs),
                attempts: traces,
                timestampMs: RainCheckTime.nowMillis(),
                refreshedAccount: credentialsRefreshed ? currentAccount : nil
            )
        }

        for spec in candidates {
            if Task.isCancelled {
                return SignResult(
                    accountId: currentAccount.id,
                    accountLabel: currentAccount.label,
                    host: currentAccount.host,
                    state: .failed,
                    strategyId: bestFailure?.strategyId,
                    httpStatus: bestFailure?.httpStatus,
                    businessCode: bestFailure?.businessCode,
                    message: "签到任务已取消",
                    elapsedMs: max(0, RainCheckTime.nowMillis() - startedMs),
                    attempts: traces,
                    timestampMs: RainCheckTime.nowMillis(),
                    refreshedAccount: credentialsRefreshed ? currentAccount : nil
                )
            }

            let variables = buildVariables(
                account: currentAccount,
                context: context,
                ticket: ticket,
                spec: spec
            )

            let outcome = await executeStrategy(
                spec: spec,
                variables: variables,
                context: context,
                ticket: ticket,
                account: &currentAccount,
                credentialsRefreshed: &credentialsRefreshed
            )
            traces.append(contentsOf: outcome.traces)

            guard let finalTrace = outcome.traces.last else { continue }
            let classified = outcome.finalState

            if classified == .success || classified == .already {
                let defaultMessage = (classified == .already) ? "已签到" : "签到成功"
                let effectiveMsg = finalTrace.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? defaultMessage
                    : finalTrace.message
                return SignResult(
                    accountId: currentAccount.id,
                    accountLabel: currentAccount.label,
                    host: currentAccount.host,
                    state: classified,
                    strategyId: spec.id,
                    httpStatus: finalTrace.httpStatus,
                    businessCode: finalTrace.businessCode,
                    message: effectiveMsg,
                    elapsedMs: max(0, RainCheckTime.nowMillis() - startedMs),
                    attempts: traces,
                    timestampMs: RainCheckTime.nowMillis(),
                    refreshedAccount: credentialsRefreshed ? currentAccount : nil
                )
            }

            let effectiveFailureMsg = finalTrace.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? (finalTrace.httpStatus.map { "HTTP \($0)（空响应）" } ?? "策略执行失败")
                : finalTrace.message

            if classified == .authExpired {
                return SignResult(
                    accountId: currentAccount.id,
                    accountLabel: currentAccount.label,
                    host: currentAccount.host,
                    state: .authExpired,
                    strategyId: spec.id,
                    httpStatus: finalTrace.httpStatus,
                    businessCode: finalTrace.businessCode,
                    message: appendHostMismatchHintIfNeeded(
                        message: effectiveFailureMsg,
                        account: currentAccount,
                        ticket: ticket
                    ),
                    elapsedMs: max(0, RainCheckTime.nowMillis() - startedMs),
                    attempts: traces,
                    timestampMs: RainCheckTime.nowMillis(),
                    refreshedAccount: credentialsRefreshed ? currentAccount : nil
                )
            }

            if classified == .qrExpired && stopWhenQrExpired {
                return SignResult(
                    accountId: currentAccount.id,
                    accountLabel: currentAccount.label,
                    host: currentAccount.host,
                    state: .qrExpired,
                    strategyId: spec.id,
                    httpStatus: finalTrace.httpStatus,
                    businessCode: finalTrace.businessCode,
                    message: appendHostMismatchHintIfNeeded(
                        message: effectiveFailureMsg,
                        account: currentAccount,
                        ticket: ticket
                    ),
                    elapsedMs: max(0, RainCheckTime.nowMillis() - startedMs),
                    attempts: traces,
                    timestampMs: RainCheckTime.nowMillis(),
                    refreshedAccount: credentialsRefreshed ? currentAccount : nil
                )
            }

            let candidate = FailureCandidate(
                priority: failurePriority(
                    state: classified,
                    strategyId: spec.id,
                    httpStatus: finalTrace.httpStatus,
                    businessCode: finalTrace.businessCode,
                    isHtmlBody: outcome.lastWasHtml,
                    hasJsonMessage: outcome.lastHadJsonMessage
                ),
                state: classified,
                strategyId: spec.id,
                httpStatus: finalTrace.httpStatus,
                businessCode: finalTrace.businessCode,
                message: effectiveFailureMsg
            )
            updateBestFailure(&bestFailure, with: candidate)
        }

        let networkTraces = traces.filter {
            $0.httpStatus != nil && $0.strategyId != "DISCOVER_ACTIVE_LESSON"
        }
        let allNetworkErrors = !networkTraces.isEmpty && networkTraces.allSatisfy {
            classify(
                httpStatus: $0.httpStatus,
                businessCode: $0.businessCode,
                message: $0.message,
                bodyText: ""
            ) == .networkError
        }

        let resolvedState: SignState
        let resolvedStrategyId: String?
        let resolvedHttpStatus: Int?
        let resolvedBusinessCode: Int?
        let resolvedMessage: String

        if allNetworkErrors {
            resolvedState = .networkError
            let chosen = bestFailure
            resolvedStrategyId = chosen?.strategyId ?? networkTraces.last?.strategyId
            resolvedHttpStatus = chosen?.httpStatus ?? networkTraces.last?.httpStatus
            resolvedBusinessCode = chosen?.businessCode ?? networkTraces.last?.businessCode
            resolvedMessage = chosen?.message ?? networkTraces.last?.message ?? "网络连接异常"
        } else if let bestFailure {
            resolvedState = (bestFailure.state == .success || bestFailure.state == .already) ? .failed : bestFailure.state
            resolvedStrategyId = bestFailure.strategyId ?? traces.last?.strategyId
            resolvedHttpStatus = bestFailure.httpStatus
            resolvedBusinessCode = bestFailure.businessCode
            resolvedMessage = bestFailure.message
        } else {
            resolvedState = .failed
            resolvedStrategyId = traces.last?.strategyId
            resolvedHttpStatus = traces.last?.httpStatus
            resolvedBusinessCode = traces.last?.businessCode
            resolvedMessage = traces.last?.message.isEmpty == false ? (traces.last?.message ?? "所有策略均被拒绝") : "所有策略均被拒绝"
        }

        return SignResult(
            accountId: currentAccount.id,
            accountLabel: currentAccount.label,
            host: currentAccount.host,
            state: resolvedState,
            strategyId: resolvedStrategyId,
            httpStatus: resolvedHttpStatus,
            businessCode: resolvedBusinessCode,
            message: appendHostMismatchHintIfNeeded(
                message: resolvedMessage,
                account: currentAccount,
                ticket: ticket
            ),
            elapsedMs: max(0, RainCheckTime.nowMillis() - startedMs),
            attempts: traces,
            timestampMs: RainCheckTime.nowMillis(),
            refreshedAccount: credentialsRefreshed ? currentAccount : nil
        )
    }

    /// 并发批量签到（可取消、严格限制并发上限、实时进度回调、保持账号顺序）。
    func checkInBatch(
        accounts: [Account],
        ticket: QrTicket,
        dryRun: Bool = false,
        maxConcurrency: Int = 4,
        onProgress: (@Sendable (SignResult) -> Void)? = nil
    ) async -> [SignResult] {
        let targets = accounts.filter(\.enabled)
        if targets.isEmpty {
            return []
        }

        let limit = max(1, min(maxConcurrency, 32))
        let batchStartNs = DispatchTime.now().uptimeNanoseconds
        var orderedResults = Array<SignResult?>(repeating: nil, count: targets.count)

        await withTaskGroup(of: (Int, SignResult).self) { group in
            var nextIndex = 0
            let initialCount = min(limit, targets.count)

            for _ in 0..<initialCount {
                let idx = nextIndex
                let account = targets[idx]
                nextIndex += 1
                group.addTask { [self] in
                    await self.applyStaggerDelayIfNeeded(index: idx, dryRun: dryRun, batchStartNs: batchStartNs)
                    let result = await self.checkIn(account: account, ticket: ticket, dryRun: dryRun)
                    return (idx, result)
                }
            }

            while let (idx, result) = await group.next() {
                orderedResults[idx] = result
                onProgress?(result)

                if !Task.isCancelled && nextIndex < targets.count {
                    let nextIdx = nextIndex
                    let nextAccount = targets[nextIdx]
                    nextIndex += 1
                    group.addTask { [self] in
                        await self.applyStaggerDelayIfNeeded(index: nextIdx, dryRun: dryRun, batchStartNs: batchStartNs)
                        let nextResult = await self.checkIn(account: nextAccount, ticket: ticket, dryRun: dryRun)
                        return (nextIdx, nextResult)
                    }
                }
            }
        }

        return orderedResults.compactMap { $0 }
    }

    private func applyStaggerDelayIfNeeded(index: Int, dryRun: Bool, batchStartNs: UInt64) async {
        guard !dryRun, staggerMs > 0, index > 0 else { return }
        let targetNs = batchStartNs &+ (UInt64(index) * staggerMs * 1_000_000)
        let nowNs = DispatchTime.now().uptimeNanoseconds
        if targetNs > nowNs {
            try? await Task.sleep(nanoseconds: targetNs - nowNs)
        }
    }

    // MARK: - Classification & Official RainClassroom 1.3.6 Error Mapping

    /// 结果状态归类：修复 HTTP 403 误判鉴权过期、HTTP 404 “不存在”误判二维码过期、
    /// HTML `<script>` 误匹配 `"token"`、以及官方雨课堂 1.3.6 业务码映射。
    func classify(
        httpStatus: Int?,
        businessCode: Int?,
        message: String?,
        bodyText: String,
        isHtmlBody: Bool = false,
        jsonSuccess: Bool? = nil
    ) -> SignState {
        if httpStatus == -1 {
            return .networkError
        }
        if httpStatus == 401 {
            return .authExpired
        }

        let trimmedMsg = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let looksLikeHtml = isHtmlBody || (trimmedMsg.isEmpty && RainCheckClient.looksLikeHTML(bodyText))
        let text: String
        if !trimmedMsg.isEmpty {
            text = trimmedMsg
        } else if looksLikeHtml {
            text = RainCheckClient.extractHTMLTitle(from: bodyText) ?? ""
        } else {
            text = bodyText
        }

        let isServerOrRetryable: Bool
        if let status = httpStatus {
            isServerOrRetryable = status >= 500 || profile.result.retryHttpStatus.contains(status)
        } else {
            isServerOrRetryable = false
        }

        if httpStatus != nil
            && !isServerOrRetryable
            && httpStatus != 403
            && httpStatus != 404
            && matchesAnyKeyword(text, keywords: profile.result.alreadyKeywords) {
            return .already
        }

        if let status = httpStatus, (200...299).contains(status) {
            if profile.result.isOkCode(businessCode) {
                return .success
            }
            if jsonSuccess == true && businessCode == nil {
                return .success
            }
        }

        if businessCode == 401 {
            return .authExpired
        }

        // 官方雨课堂 1.3.6 实证业务码优先归类（避免 50019“学校身份”被 authKeywords 中的“身份”误判为登录过期）
        if let code = businessCode {
            switch code {
            case 50019, 50015, 50017, 50004, 50021, 50023, 50003:
                return .notInClass
            case 50070:
                return .failed
            case 51203:
                if matchesAnyKeyword(text, keywords: ["过期", "失效", "expired", "refused", "二维码已"]) {
                    return .qrExpired
                }
                return .failed
            default:
                break
            }
        }

        // HTTP 403 精细判断：仅在明确命中鉴权关键词或 CSRF 校验失败时归类为 .authExpired，
        // 避免业务拒绝 / 策略禁止返回 403 时错误中止后续兜底策略
        if httpStatus == 403 {
            if Self.isCsrf403(httpStatus: httpStatus, message: message, bodyText: bodyText)
                || matchesAnyKeyword(text, keywords: profile.result.authKeywords) {
                return .authExpired
            }
            if matchesAnyKeyword(text, keywords: ["过期", "失效", "qr code expired", "qrcode expired", "二维码已"]) {
                return .qrExpired
            }
            return .failed
        }

        if matchesAnyKeyword(text, keywords: profile.result.authKeywords) {
            return .authExpired
        }

        // HTTP 404 路由不存在守卫：绝不因 404 “接口不存在”/HTML 404/空体误判为 .qrExpired 而中断后续策略
        if Self.isHttp404RouteNotFound(
            httpStatus: httpStatus,
            businessCode: businessCode,
            text: text,
            looksLikeHtml: looksLikeHtml
        ) {
            return .failed
        }

        if matchesAnyKeyword(text, keywords: profile.result.expiredKeywords)
            || matchesAnyKeyword(text, keywords: ["dynamic qr check in refused", "qr code expired", "qrcode expired"]) {
            return .qrExpired
        }

        if isServerOrRetryable {
            return .networkError
        }

        if matchesAnyKeyword(text, keywords: [
            "未加入", "不在课堂", "不在该课", "非本班", "不在班级",
            "未绑定学校", "入班限制", "人数已达上限", "课堂已结束"
        ]) {
            return .notInClass
        }

        return .failed
    }

    private func mapServerDiagnosticMessage(for result: ApiCallResult) -> String {
        let rawMsg = result.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if let code = result.businessCode {
            switch code {
            case 51203:
                return rawMsg.isEmpty ? "二维码无效或已过期（51203）" : rawMsg
            case 50070:
                if rawMsg.isEmpty {
                    return "动态二维码校验未通过或课堂已结束"
                }
                if rawMsg.contains("动态二维码") || rawMsg.contains("课堂已结束") {
                    return rawMsg
                }
                return "动态二维码校验未通过或课堂已结束（\(rawMsg)）"
            case 50019, 50015:
                if rawMsg.isEmpty {
                    return "账号未绑定学校身份，请在官方雨课堂完成身份绑定"
                }
                if rawMsg.contains("绑定") {
                    return rawMsg
                }
                return "账号未绑定学校身份（\(rawMsg)）"
            case 50017:
                if rawMsg.isEmpty {
                    return "教师已设置入班限制，无法自动加入课堂"
                }
                if rawMsg.contains("入班限制") {
                    return rawMsg
                }
                return "教师已设置入班限制（\(rawMsg)）"
            case 50004:
                if rawMsg.isEmpty {
                    return "课堂已结束，无法签到"
                }
                if rawMsg.contains("课堂已结束") {
                    return rawMsg
                }
                return "课堂已结束，无法签到（\(rawMsg)）"
            case 50021:
                if rawMsg.isEmpty {
                    return "课堂人数已达上限，无法加入"
                }
                if rawMsg.contains("上限") {
                    return rawMsg
                }
                return "课堂人数已达上限（\(rawMsg)）"
            case 50023, 50003:
                if rawMsg.isEmpty {
                    return "课堂或签到码不存在"
                }
                if rawMsg.contains("不存在") {
                    return rawMsg
                }
                return "课堂或签到码不存在（\(rawMsg)）"
            default:
                break
            }
        }

        if !rawMsg.isEmpty {
            let lower = rawMsg.lowercased()
            if lower.contains("dynamic qr check in refused") {
                return "动态二维码签到被拒绝（\(rawMsg)）"
            }
            if lower.contains("qr code expired") || lower.contains("qrcode expired") {
                return "二维码已过期（\(rawMsg)）"
            }
        }

        if result.httpStatus == 403 && Self.isCsrf403(httpStatus: result.httpStatus, message: result.message, bodyText: result.bodyText) {
            if !rawMsg.isEmpty {
                return "CSRF 校验失败（HTTP 403：\(rawMsg)）"
            }
            return "CSRF 校验失败（HTTP 403），请重新登录以刷新 csrftoken"
        }

        return result.diagnosticSummary
    }

    private static func isCsrf403(httpStatus: Int?, message: String?, bodyText: String) -> Bool {
        guard httpStatus == 403 else { return false }
        let msgLower = (message ?? "").lowercased()
        if msgLower.contains("csrf") {
            return true
        }
        let bodyLower = bodyText.lowercased()
        return bodyLower.contains("csrf verification failed")
            || bodyLower.contains("csrf cookie not set")
            || bodyLower.contains("csrf token missing")
            || bodyLower.contains("csrf_token")
            || bodyLower.contains("csrftoken")
    }

    private static func isHttp404RouteNotFound(
        httpStatus: Int?,
        businessCode: Int?,
        text: String,
        looksLikeHtml: Bool
    ) -> Bool {
        guard httpStatus == 404 else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || looksLikeHtml {
            return true
        }
        if businessCode == 404 || businessCode == 40400 {
            return true
        }
        let lower = trimmed.lowercased()
        let routeHints = [
            "接口不存在", "路径不存在", "路由不存在", "页面不存在",
            "not found", "404", "no such route", "method not allowed"
        ]
        if routeHints.contains(where: { lower.contains($0) }) {
            return true
        }
        if lower.contains("不存在")
            && !lower.contains("二维码")
            && !lower.contains("签到码")
            && !lower.contains("动态码")
            && !lower.contains("过期")
            && !lower.contains("失效") {
            return true
        }
        return false
    }

    // MARK: - Priority #1 Official RainClassroom 1.3.6 APP_SCAN_CHECKIN Flow

    private struct FailureCandidate {
        let priority: Int
        let state: SignState
        let strategyId: String?
        let httpStatus: Int?
        let businessCode: Int?
        let message: String
    }

    private enum AppScanOutcome {
        case terminal(SignResult)
        case fallback(
            discoveredContext: LessonContext?,
            bestFailure: FailureCandidate?,
            traces: [AttemptTrace]
        )
    }

    private func shouldRunAppScan(for ticket: QrTicket) -> Bool {
        guard profile.endpoint("appScan") != nil,
              profile.endpoint("checkinAppScan") != nil else {
            return false
        }
        guard !ticket.raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        if let url = ticket.url, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return ticket.kind == .unknown
    }

    private func executeAppScanFlow(
        ticket: QrTicket,
        startedMs: Int64,
        account: inout Account,
        credentialsRefreshed: inout Bool,
        existingTraces: [AttemptTrace]
    ) async -> AppScanOutcome {
        var localTraces: [AttemptTrace] = []
        var bestAppFailure: FailureCandidate?

        let step1Call = await callEndpointForAppScan(
            endpointKey: "appScan",
            variables: ["qrRaw": .string(ticket.raw)],
            markOkOnSuccess: false,
            account: &account,
            credentialsRefreshed: &credentialsRefreshed
        )
        localTraces.append(contentsOf: step1Call.traces)

        if Task.isCancelled {
            return .terminal(
                SignResult(
                    accountId: account.id,
                    accountLabel: account.label,
                    host: account.host,
                    state: .failed,
                    strategyId: Self.appScanStrategyId,
                    httpStatus: step1Call.result.httpStatus,
                    businessCode: step1Call.result.businessCode,
                    message: "签到任务已取消",
                    elapsedMs: max(0, RainCheckTime.nowMillis() - startedMs),
                    attempts: existingTraces + localTraces,
                    timestampMs: RainCheckTime.nowMillis(),
                    refreshedAccount: credentialsRefreshed ? account : nil
                )
            )
        }

        let scanResult = step1Call.result
        let scanState = step1Call.state
        let scanDiagMsg = mapServerDiagnosticMessage(for: scanResult)

        // 1) Step 1 在 x-client: app 下返回鉴权失败：不直接误杀仅持有 Web sessionid 的有效账号，
        // 交由后续 X-Client: web 的课堂发现与兜底策略验证（若 Web 会话同样过期，首条 Web 请求会立即中止为 .authExpired）
        if scanState == .authExpired {
            updateBestFailure(
                &bestAppFailure,
                with: FailureCandidate(
                    priority: 140,
                    state: .authExpired,
                    strategyId: Self.appScanStrategyId,
                    httpStatus: scanResult.httpStatus,
                    businessCode: scanResult.businessCode,
                    message: scanDiagMsg
                )
            )
            return .fallback(discoveredContext: nil, bestFailure: bestAppFailure, traces: localTraces)
        }

        // 2) 旧版服务/本地演练未实现 /api/v3/app/scan（404 / 405）：记录低优先级轨迹并无缝回退
        if scanResult.httpStatus == 404 || scanResult.httpStatus == 405 {
            updateBestFailure(
                &bestAppFailure,
                with: FailureCandidate(
                    priority: 100,
                    state: .failed,
                    strategyId: Self.appScanStrategyId,
                    httpStatus: scanResult.httpStatus,
                    businessCode: scanResult.businessCode,
                    message: scanDiagMsg
                )
            )
            return .fallback(discoveredContext: nil, bestFailure: bestAppFailure, traces: localTraces)
        }

        // 3) 官方 51203：保留 scanBean.msg 原文；若提示过期/失效则直接归类 .qrExpired 中止
        if scanResult.businessCode == 51203 {
            let exactMsg = scanResult.message?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? (scanResult.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "二维码无效或已过期（51203）")
                : "二维码无效或已过期（51203）"
            let indicatesExpiry = matchesAnyKeyword(
                exactMsg,
                keywords: ["过期", "失效", "expired", "refused", "二维码已"]
            )
            if indicatesExpiry && stopWhenQrExpired {
                return .terminal(
                    SignResult(
                        accountId: account.id,
                        accountLabel: account.label,
                        host: account.host,
                        state: .qrExpired,
                        strategyId: Self.appScanStrategyId,
                        httpStatus: scanResult.httpStatus,
                        businessCode: 51203,
                        message: appendHostMismatchHintIfNeeded(
                            message: exactMsg,
                            account: account,
                            ticket: ticket
                        ),
                        elapsedMs: max(0, RainCheckTime.nowMillis() - startedMs),
                        attempts: existingTraces + localTraces,
                        timestampMs: RainCheckTime.nowMillis(),
                        refreshedAccount: credentialsRefreshed ? account : nil
                    )
                )
            }
            updateBestFailure(
                &bestAppFailure,
                with: FailureCandidate(
                    priority: 400,
                    state: indicatesExpiry ? .qrExpired : .failed,
                    strategyId: Self.appScanStrategyId,
                    httpStatus: scanResult.httpStatus,
                    businessCode: 51203,
                    message: exactMsg
                )
            )
            return .fallback(discoveredContext: nil, bestFailure: bestAppFailure, traces: localTraces)
        }

        // 4) 传输异常或 5xx：若显式提示二维码过期则中止，否则无缝回退
        if scanResult.httpStatus == -1 || (500...599).contains(scanResult.httpStatus) {
            if scanState == .qrExpired && stopWhenQrExpired {
                return .terminal(
                    SignResult(
                        accountId: account.id,
                        accountLabel: account.label,
                        host: account.host,
                        state: .qrExpired,
                        strategyId: Self.appScanStrategyId,
                        httpStatus: scanResult.httpStatus,
                        businessCode: scanResult.businessCode,
                        message: appendHostMismatchHintIfNeeded(
                            message: scanDiagMsg,
                            account: account,
                            ticket: ticket
                        ),
                        elapsedMs: max(0, RainCheckTime.nowMillis() - startedMs),
                        attempts: existingTraces + localTraces,
                        timestampMs: RainCheckTime.nowMillis(),
                        refreshedAccount: credentialsRefreshed ? account : nil
                    )
                )
            }
            updateBestFailure(
                &bestAppFailure,
                with: FailureCandidate(
                    priority: 200,
                    state: .networkError,
                    strategyId: Self.appScanStrategyId,
                    httpStatus: scanResult.httpStatus,
                    businessCode: scanResult.businessCode,
                    message: scanDiagMsg
                )
            )
            return .fallback(discoveredContext: nil, bestFailure: bestAppFailure, traces: localTraces)
        }

        // 5) Step 1 成功：按官方 ScanBean.data.type 分发
        if scanResult.ok {
            let scanData = scanResult.dataObject
            let scanType = scanData?.firstNonBlankString("type")?.lowercased()
            let scanValue = scanData?.firstNonBlankString("value", "lesson_id", "lessonId")
            let scanClassroomId = scanData?.firstNonBlankString("classroom_id", "classroomId")
            let scanTitle = scanData?.firstNonBlankString("title", "classroom_name")

            if scanType == "login" || scanType == "app_web_login" {
                return .terminal(
                    SignResult(
                        accountId: account.id,
                        accountLabel: account.label,
                        host: account.host,
                        state: .notInClass,
                        strategyId: Self.appScanStrategyId,
                        httpStatus: scanResult.httpStatus,
                        businessCode: scanResult.businessCode,
                        message: "服务端识别为登录二维码而非课堂签到码",
                        elapsedMs: max(0, RainCheckTime.nowMillis() - startedMs),
                        attempts: existingTraces + localTraces,
                        timestampMs: RainCheckTime.nowMillis(),
                        refreshedAccount: credentialsRefreshed ? account : nil
                    )
                )
            }

            if scanType == "classroom" {
                let valueDesc = scanValue ?? "未知"
                return .terminal(
                    SignResult(
                        accountId: account.id,
                        accountLabel: account.label,
                        host: account.host,
                        state: .notInClass,
                        strategyId: Self.appScanStrategyId,
                        httpStatus: scanResult.httpStatus,
                        businessCode: scanResult.businessCode,
                        message: "这是加班二维码而非签到码（classroomId=\(valueDesc)）",
                        elapsedMs: max(0, RainCheckTime.nowMillis() - startedMs),
                        attempts: existingTraces + localTraces,
                        timestampMs: RainCheckTime.nowMillis(),
                        refreshedAccount: credentialsRefreshed ? account : nil
                    )
                )
            }

            if scanType == "checkin", let value = scanValue, !value.isEmpty {
                let discoveredContext = LessonContext(
                    lessonId: value,
                    classroomId: scanClassroomId ?? ticket.classroomId,
                    name: scanTitle
                )

                // Step 2a: 调用官方 POST /api/v3/lesson/checkin (source=21, joinIfNotIn=true, x-client: app)
                let step2Call = await callEndpointForAppScan(
                    endpointKey: "checkinAppScan",
                    variables: ["lessonId": .string(value)],
                    markOkOnSuccess: true,
                    account: &account,
                    credentialsRefreshed: &credentialsRefreshed
                )
                localTraces.append(contentsOf: step2Call.traces)

                if step2Call.state == .authExpired && !Task.isCancelled {
                    // 实网修复：Web PC 手机号登录或浏览器导入的 sessionid 在 x-client: app 下会被 /api/v3/lesson/checkin
                    // 拒签返回 HTTP 200 code 50000 UNAUTHENTICATED（而 X-Client: web 的 basic-info 凭据校验有效）。
                    // 立即以与 basic-info 一致的 X-Client: web 请求头重试同载荷；若仍未通过则继续复用已发现的 lessonId 走 Web 兜底链。
                    let base = "\(account.scheme)://\(account.host)"
                    let webReferer: String
                    if let cid = discoveredContext.classroomId, !cid.isEmpty {
                        webReferer = "\(base)/v2/web/studentLog/\(cid)"
                    } else {
                        webReferer = "\(base)/v2/web/index"
                    }
                    let webRetryCall = await callEndpointForAppScan(
                        endpointKey: "checkinAppScan",
                        variables: ["lessonId": .string(value)],
                        strategyId: Self.appScanWebStrategyId,
                        referer: webReferer,
                        extraHeaders: ["X-Client": "web"],
                        markOkOnSuccess: true,
                        account: &account,
                        credentialsRefreshed: &credentialsRefreshed
                    )
                    localTraces.append(contentsOf: webRetryCall.traces)

                    if let terminal = evaluateAppScanStep2(
                        call: webRetryCall,
                        strategyId: Self.appScanWebStrategyId,
                        ticket: ticket,
                        startedMs: startedMs,
                        account: account,
                        credentialsRefreshed: credentialsRefreshed,
                        allTraces: existingTraces + localTraces,
                        bestFailure: &bestAppFailure,
                        abortOnAuthExpired: false
                    ) {
                        return .terminal(terminal)
                    }
                } else if let terminal = evaluateAppScanStep2(
                    call: step2Call,
                    ticket: ticket,
                    startedMs: startedMs,
                    account: account,
                    credentialsRefreshed: credentialsRefreshed,
                    allTraces: existingTraces + localTraces,
                    bestFailure: &bestAppFailure,
                    abortOnAuthExpired: true
                ) {
                    return .terminal(terminal)
                }

                // Step 2b: 若 value.count <= 11（旧版 v2 lesson_id），补充尝试 checkinWeb 兜底
                if value.count <= 11 && !Task.isCancelled && profile.endpoint("checkinWeb") != nil {
                    let webCall = await callEndpointForAppScan(
                        endpointKey: "checkinWeb",
                        variables: ["lessonId": .string(value)],
                        markOkOnSuccess: true,
                        account: &account,
                        credentialsRefreshed: &credentialsRefreshed
                    )
                    localTraces.append(contentsOf: webCall.traces)

                    if let terminal = evaluateAppScanStep2(
                        call: webCall,
                        ticket: ticket,
                        startedMs: startedMs,
                        account: account,
                        credentialsRefreshed: credentialsRefreshed,
                        allTraces: existingTraces + localTraces,
                        bestFailure: &bestAppFailure,
                        abortOnAuthExpired: true
                    ) {
                        return .terminal(terminal)
                    }
                }

                return .fallback(
                    discoveredContext: discoveredContext,
                    bestFailure: bestAppFailure,
                    traces: localTraces
                )
            }

            // 响应未携带可识别的 data.type（例如非标准或测试服务器）：不中止，交由后续策略处理
            return .fallback(discoveredContext: nil, bestFailure: nil, traces: localTraces)
        }

        // 6) Step 1 返回其他非 0 业务错误
        if scanState == .qrExpired && stopWhenQrExpired {
            return .terminal(
                SignResult(
                    accountId: account.id,
                    accountLabel: account.label,
                    host: account.host,
                    state: .qrExpired,
                    strategyId: Self.appScanStrategyId,
                    httpStatus: scanResult.httpStatus,
                    businessCode: scanResult.businessCode,
                    message: appendHostMismatchHintIfNeeded(
                        message: scanDiagMsg,
                        account: account,
                        ticket: ticket
                    ),
                    elapsedMs: max(0, RainCheckTime.nowMillis() - startedMs),
                    attempts: existingTraces + localTraces,
                    timestampMs: RainCheckTime.nowMillis(),
                    refreshedAccount: credentialsRefreshed ? account : nil
                )
            )
        }

        updateBestFailure(
            &bestAppFailure,
            with: FailureCandidate(
                priority: failurePriority(
                    state: scanState,
                    strategyId: Self.appScanStrategyId,
                    httpStatus: scanResult.httpStatus,
                    businessCode: scanResult.businessCode,
                    isHtmlBody: scanResult.isHtmlBody,
                    hasJsonMessage: !(scanResult.message?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                ),
                state: scanState,
                strategyId: Self.appScanStrategyId,
                httpStatus: scanResult.httpStatus,
                businessCode: scanResult.businessCode,
                message: scanDiagMsg
            )
        )
        return .fallback(discoveredContext: nil, bestFailure: bestAppFailure, traces: localTraces)
    }

    private func evaluateAppScanStep2(
        call: (result: ApiCallResult, state: SignState, traces: [AttemptTrace]),
        strategyId: String = CheckInOrchestrator.appScanStrategyId,
        ticket: QrTicket,
        startedMs: Int64,
        account: Account,
        credentialsRefreshed: Bool,
        allTraces: [AttemptTrace],
        bestFailure: inout FailureCandidate?,
        abortOnAuthExpired: Bool = true
    ) -> SignResult? {
        if Task.isCancelled {
            return SignResult(
                accountId: account.id,
                accountLabel: account.label,
                host: account.host,
                state: .failed,
                strategyId: strategyId,
                httpStatus: call.result.httpStatus,
                businessCode: call.result.businessCode,
                message: "签到任务已取消",
                elapsedMs: max(0, RainCheckTime.nowMillis() - startedMs),
                attempts: allTraces,
                timestampMs: RainCheckTime.nowMillis(),
                refreshedAccount: credentialsRefreshed ? account : nil
            )
        }

        let res = call.result
        let state = call.state
        let diagMsg = mapServerDiagnosticMessage(for: res)

        if state == .success || state == .already {
            let defaultMsg = (state == .already) ? "已签到" : "签到成功"
            let rawMsg = res.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return SignResult(
                accountId: account.id,
                accountLabel: account.label,
                host: account.host,
                state: state,
                strategyId: strategyId,
                httpStatus: res.httpStatus,
                businessCode: res.businessCode,
                message: rawMsg.isEmpty ? defaultMsg : rawMsg,
                elapsedMs: max(0, RainCheckTime.nowMillis() - startedMs),
                attempts: allTraces,
                timestampMs: RainCheckTime.nowMillis(),
                refreshedAccount: credentialsRefreshed ? account : nil
            )
        }

        if state == .authExpired && abortOnAuthExpired {
            return SignResult(
                accountId: account.id,
                accountLabel: account.label,
                host: account.host,
                state: .authExpired,
                strategyId: strategyId,
                httpStatus: res.httpStatus,
                businessCode: res.businessCode,
                message: appendHostMismatchHintIfNeeded(
                    message: diagMsg,
                    account: account,
                    ticket: ticket
                ),
                elapsedMs: max(0, RainCheckTime.nowMillis() - startedMs),
                attempts: allTraces,
                timestampMs: RainCheckTime.nowMillis(),
                refreshedAccount: credentialsRefreshed ? account : nil
            )
        }

        if state == .qrExpired && stopWhenQrExpired {
            return SignResult(
                accountId: account.id,
                accountLabel: account.label,
                host: account.host,
                state: .qrExpired,
                strategyId: strategyId,
                httpStatus: res.httpStatus,
                businessCode: res.businessCode,
                message: appendHostMismatchHintIfNeeded(
                    message: diagMsg,
                    account: account,
                    ticket: ticket
                ),
                elapsedMs: max(0, RainCheckTime.nowMillis() - startedMs),
                attempts: allTraces,
                timestampMs: RainCheckTime.nowMillis(),
                refreshedAccount: credentialsRefreshed ? account : nil
            )
        }

        updateBestFailure(
            &bestFailure,
            with: FailureCandidate(
                priority: failurePriority(
                    state: state,
                    strategyId: strategyId,
                    httpStatus: res.httpStatus,
                    businessCode: res.businessCode,
                    isHtmlBody: res.isHtmlBody,
                    hasJsonMessage: !(res.message?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                ),
                state: state,
                strategyId: strategyId,
                httpStatus: res.httpStatus,
                businessCode: res.businessCode,
                message: diagMsg
            )
        )
        return nil
    }

    private func callEndpointForAppScan(
        endpointKey: String,
        variables: [String: TemplateValue],
        strategyId: String = CheckInOrchestrator.appScanStrategyId,
        referer: String? = nil,
        extraHeaders: [String: String] = [:],
        markOkOnSuccess: Bool,
        account: inout Account,
        credentialsRefreshed: inout Bool
    ) async -> (result: ApiCallResult, state: SignState, traces: [AttemptTrace]) {
        var recorded: [AttemptTrace] = []
        var triedCookieOnlyFallback = false
        let fastMaxAttempts = min(maxAttemptsPerStrategy, 2)
        let fastBackoffMs = min(baseBackoffMs, 250)

        var lastResult: ApiCallResult?
        var lastState: SignState = .failed

        for attemptIndex in 0..<fastMaxAttempts {
            if Task.isCancelled {
                break
            }

            let initialResult = await client.executeEndpoint(
                endpointKey,
                account: account,
                variables: variables,
                extraCookies: [:],
                referer: referer,
                extraHeaders: extraHeaders
            )
            let initialState = classify(
                httpStatus: initialResult.httpStatus,
                businessCode: initialResult.businessCode,
                message: initialResult.message,
                bodyText: initialResult.bodyText,
                isHtmlBody: initialResult.isHtmlBody,
                jsonSuccess: initialResult.jsonSuccess
            )
            let initialIsOk = (initialState == .success || initialState == .already)
            recorded.append(makeTrace(strategyId: strategyId, result: initialResult))

            var effectiveResult = initialResult
            var effectiveState = initialState
            var effectiveIsOk = initialIsOk

            let hasBearer = !(account.bearer?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            let hasSession = !(account.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

            if initialState == .authExpired && hasBearer && hasSession && !triedCookieOnlyFallback && !Task.isCancelled {
                triedCookieOnlyFallback = true
                var cookieOnlyAccount = account
                cookieOnlyAccount.bearer = nil

                let retryResult = await client.executeEndpoint(
                    endpointKey,
                    account: cookieOnlyAccount,
                    variables: variables,
                    extraCookies: [:],
                    referer: referer,
                    extraHeaders: extraHeaders
                )
                let retryState = classify(
                    httpStatus: retryResult.httpStatus,
                    businessCode: retryResult.businessCode,
                    message: retryResult.message,
                    bodyText: retryResult.bodyText,
                    isHtmlBody: retryResult.isHtmlBody,
                    jsonSuccess: retryResult.jsonSuccess
                )
                let retryIsOk = (retryState == .success || retryState == .already)
                recorded.append(makeTrace(strategyId: strategyId, result: retryResult))

                effectiveResult = retryResult
                effectiveState = retryState
                effectiveIsOk = retryIsOk

                let cookieAuthAccepted = retryIsOk
                    || ((200...299).contains(retryResult.httpStatus)
                        && retryState != .authExpired
                        && retryState != .networkError)
                if cookieAuthAccepted {
                    account = cookieOnlyAccount
                    credentialsRefreshed = true
                    applyAuthUpdateIfChanged(
                        auth: retryResult.authUpdate,
                        markOk: markOkOnSuccess && retryIsOk,
                        account: &account,
                        credentialsRefreshed: &credentialsRefreshed
                    )
                }
            } else {
                applyAuthUpdateIfChanged(
                    auth: initialResult.authUpdate,
                    markOk: markOkOnSuccess && initialIsOk,
                    account: &account,
                    credentialsRefreshed: &credentialsRefreshed
                )
            }

            lastResult = effectiveResult
            lastState = effectiveState

            let transientRetryable = effectiveResult.httpStatus == -1
                || effectiveResult.httpStatus == 502
                || effectiveResult.httpStatus == 503
                || effectiveResult.httpStatus == 504
            let abortImmediately = (effectiveState == .qrExpired || effectiveState == .authExpired)

            if effectiveIsOk || abortImmediately || !transientRetryable || attemptIndex >= fastMaxAttempts - 1 || Task.isCancelled {
                break
            }
            if fastBackoffMs > 0 {
                try? await Task.sleep(nanoseconds: fastBackoffMs * 1_000_000)
            }
        }

        let finalResult = lastResult ?? ApiCallResult(
            httpStatus: -1,
            bodyText: "签到任务已取消",
            jsonObject: nil,
            businessCode: nil,
            message: "签到任务已取消",
            elapsedMs: 0,
            authUpdate: nil,
            responseCookies: [:],
            ok: false,
            requestMethod: "POST",
            requestUrl: ""
        )
        return (finalResult, lastState, recorded)
    }

    // MARK: - Discovery & Fallback Strategy Execution

    private enum DiscoverOutcome {
        case found(LessonContext, [AttemptTrace])
        case authExpired(String, [AttemptTrace])
        case networkError(String, [AttemptTrace])
        case notFound(String, [AttemptTrace])
    }

    private func isDiscoverAuthFailure(_ result: ApiCallResult) -> Bool {
        if result.httpStatus == 401 {
            return true
        }
        if result.httpStatus == 403 {
            if Self.isCsrf403(httpStatus: result.httpStatus, message: result.message, bodyText: result.bodyText) {
                return true
            }
            let safeText = safeTextForKeywords(result)
            return matchesAnyKeyword(safeText, keywords: profile.result.authKeywords)
        }
        if !result.ok && result.businessCode == 401 {
            return true
        }
        if !result.ok && matchesAnyKeyword(safeTextForKeywords(result), keywords: profile.result.authKeywords) {
            return true
        }
        return false
    }

    private func safeTextForKeywords(_ result: ApiCallResult) -> String {
        let trimmed = result.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            return trimmed
        }
        if result.isHtmlBody {
            return RainCheckClient.extractHTMLTitle(from: result.bodyText) ?? ""
        }
        return result.bodyText
    }

    private func makeTrace(strategyId: String, result: ApiCallResult) -> AttemptTrace {
        AttemptTrace(
            strategyId: strategyId,
            method: result.requestMethod,
            url: result.requestUrl,
            httpStatus: result.httpStatus,
            businessCode: result.businessCode,
            message: mapServerDiagnosticMessage(for: result),
            elapsedMs: result.elapsedMs,
            rawSnippet: result.rawSnippet,
            finalUrl: result.finalUrl
        )
    }

    private func makeDiscoverTrace(for result: ApiCallResult, account: Account) -> AttemptTrace {
        let path = profile.endpoint("activeLesson")?.path ?? "/api/v3/classroom/on-lesson-upcoming-exam"
        let requestUrl = result.requestUrl.isEmpty ? "\(account.scheme)://\(account.host)\(path)" : result.requestUrl
        return AttemptTrace(
            strategyId: "DISCOVER_ACTIVE_LESSON",
            method: "GET",
            url: requestUrl,
            httpStatus: result.httpStatus,
            businessCode: result.businessCode,
            message: mapServerDiagnosticMessage(for: result),
            elapsedMs: result.elapsedMs,
            rawSnippet: result.rawSnippet,
            finalUrl: result.finalUrl
        )
    }

    private func discoverActiveLesson(
        account: inout Account,
        credentialsRefreshed: inout Bool,
        ticket: QrTicket
    ) async -> DiscoverOutcome {
        let initialActive = await client.callEndpoint("activeLesson", account: account, variables: [:])
        var recorded: [AttemptTrace] = [makeDiscoverTrace(for: initialActive, account: account)]
        var active = initialActive

        let hasBearer = !(account.bearer?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasSession = !(account.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

        if !initialActive.ok && hasBearer && hasSession && isDiscoverAuthFailure(initialActive) && !Task.isCancelled {
            var cookieOnlyAccount = account
            cookieOnlyAccount.bearer = nil
            let retryActive = await client.callEndpoint("activeLesson", account: cookieOnlyAccount, variables: [:])
            recorded.append(makeDiscoverTrace(for: retryActive, account: cookieOnlyAccount))
            active = retryActive
            if retryActive.ok {
                account = cookieOnlyAccount
                credentialsRefreshed = true
                applyAuthUpdateIfChanged(
                    auth: retryActive.authUpdate,
                    markOk: true,
                    account: &account,
                    credentialsRefreshed: &credentialsRefreshed
                )
            }
        } else {
            applyAuthUpdateIfChanged(
                auth: initialActive.authUpdate,
                markOk: initialActive.ok,
                account: &account,
                credentialsRefreshed: &credentialsRefreshed
            )
        }

        if active.httpStatus == -1 {
            return .networkError("查询进行中课堂网络异常: \(String(active.bodyText.prefix(120)))", recorded)
        }
        if isDiscoverAuthFailure(active) {
            return .authExpired(
                active.message ?? mapServerDiagnosticMessage(for: active),
                recorded
            )
        }
        if !active.ok && (active.httpStatus >= 500 || profile.result.retryHttpStatus.contains(active.httpStatus)) {
            return .networkError(
                active.message ?? "查询进行中课堂服务端异常 (HTTP \(active.httpStatus))",
                recorded
            )
        }

        if active.ok {
            let lessons = findLessonObjects(inResponse: active.jsonObject)
            let matched: LessonContext?
            if let targetClassroomId = ticket.classroomId {
                matched = lessons.first(where: { $0.classroomId == targetClassroomId }) ?? lessons.first
            } else {
                matched = lessons.first
            }
            if let matched {
                return .found(matched, recorded)
            }
        }

        return .notFound("无法确定 lessonId，请确认二维码属于进行中的课堂", recorded)
    }

    private enum PlanBuildResult {
        case endpointPlan(endpointKey: String, method: String, url: String)
        case directUrlPlan(method: String, url: String, body: [String: TemplateValue]?)
        case rejected(method: String, url: String, reason: String)
    }

    private func buildRequestPlan(
        account: Account,
        spec: StrategySpec,
        variables: [String: TemplateValue],
        ticket: QrTicket
    ) -> PlanBuildResult {
        if isQrUrlStrategy(spec.id) {
            let method = (spec.id == "QR_URL_GET") ? "GET" : "POST"
            guard let url = ticket.url, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .rejected(method: method, url: "", reason: "二维码不是 URL，跳过")
            }
            if let securityError = QrCodeParser.qrUrlValidationError(
                url,
                accountHost: account.host,
                accountScheme: account.scheme,
                profile: profile
            ) {
                return .rejected(
                    method: method,
                    url: url,
                    reason: "安全拦截：拒绝向非白名单地址发送凭据（\(securityError)）"
                )
            }
            let body: [String: TemplateValue]? = (method == "GET")
                ? nil
                : ticket.params.mapValues { TemplateValue.string($0) }
            return .directUrlPlan(method: method, url: url, body: body)
        }

        guard let endpointKey = spec.endpoint, let endpoint = profile.endpoint(endpointKey) else {
            return .rejected(method: "POST", url: "", reason: "profile 缺少 endpoint")
        }
        let base = "\(account.scheme)://\(account.host)"
        let path = TemplateRenderer.renderPath(endpoint.path, variables: variables)
        let query = TemplateRenderer.renderQuery(endpoint.query, variables: variables)
        let url = TemplateRenderer.buildURL(base: base, path: path, query: query)
        return .endpointPlan(endpointKey: endpointKey, method: endpoint.method.uppercased(), url: url)
    }

    private func simulateDryRun(
        account: Account,
        spec: StrategySpec,
        variables: [String: TemplateValue],
        ticket: QrTicket
    ) -> AttemptTrace {
        switch buildRequestPlan(account: account, spec: spec, variables: variables, ticket: ticket) {
        case .rejected(let method, let url, let reason):
            return AttemptTrace(
                strategyId: spec.id,
                method: method,
                url: url,
                httpStatus: nil,
                businessCode: nil,
                message: reason,
                elapsedMs: 0
            )
        case .endpointPlan(_, let method, let url):
            return AttemptTrace(
                strategyId: spec.id,
                method: method,
                url: url,
                httpStatus: nil,
                businessCode: nil,
                message: "演练模式，未发送",
                elapsedMs: 0
            )
        case .directUrlPlan(let method, let url, _):
            return AttemptTrace(
                strategyId: spec.id,
                method: method,
                url: url,
                httpStatus: nil,
                businessCode: nil,
                message: "演练模式，未发送",
                elapsedMs: 0
            )
        }
    }

    private func performPlan(
        _ plan: PlanBuildResult,
        account: Account,
        variables: [String: TemplateValue],
        endpointReferer: String
    ) async -> ApiCallResult? {
        switch plan {
        case .endpointPlan(let endpointKey, _, _):
            return await client.executeEndpoint(
                endpointKey,
                account: account,
                variables: variables,
                extraCookies: [:],
                referer: endpointReferer,
                extraHeaders: [:]
            )
        case .directUrlPlan(let method, let url, let body):
            // 传入 nil referer，由 RainCheckClient 自动按目标 URL 同源构造 Origin 与 Referer，杜绝跨域名 CSRF 403
            return await client.callDirectUrl(
                url,
                method: method,
                account: account,
                body: body,
                referer: nil
            )
        case .rejected:
            return nil
        }
    }

    private func executeStrategy(
        spec: StrategySpec,
        variables: [String: TemplateValue],
        context: LessonContext?,
        ticket: QrTicket,
        account: inout Account,
        credentialsRefreshed: inout Bool
    ) async -> (traces: [AttemptTrace], finalState: SignState, lastWasHtml: Bool, lastHadJsonMessage: Bool) {
        let plan = buildRequestPlan(account: account, spec: spec, variables: variables, ticket: ticket)
        if case .rejected(let method, let url, let reason) = plan {
            let trace = AttemptTrace(
                strategyId: spec.id,
                method: method,
                url: url,
                httpStatus: nil,
                businessCode: nil,
                message: reason,
                elapsedMs: 0
            )
            return ([trace], .failed, false, false)
        }

        // 动态二维码采用紧凑重试预算（最多 2 次，退避上限 250ms），避免耗尽 5~8 秒有效窗口
        let isDynamic = (ticket.kind == .dynamicCheckin)
        let effectiveMaxAttempts = isDynamic ? min(maxAttemptsPerStrategy, 2) : maxAttemptsPerStrategy
        let effectiveBaseBackoffMs = isDynamic ? min(baseBackoffMs, 250) : baseBackoffMs

        var recorded: [AttemptTrace] = []
        var finalState: SignState = .failed
        var lastWasHtml = false
        var lastHadJsonMessage = false
        var attemptIndex = 0
        var triedCookieOnlyFallback = false

        while attemptIndex < effectiveMaxAttempts {
            if Task.isCancelled {
                break
            }

            let base = "\(account.scheme)://\(account.host)"
            let endpointReferer: String
            if let classroomId = context?.classroomId, !classroomId.isEmpty {
                endpointReferer = "\(base)/v2/web/studentLog/\(classroomId)"
            } else {
                endpointReferer = "\(base)/v2/web/index"
            }

            guard let initialApiResult = await performPlan(
                plan,
                account: account,
                variables: variables,
                endpointReferer: endpointReferer
            ) else {
                return (recorded, .failed, lastWasHtml, lastHadJsonMessage)
            }

            let initialState = classify(
                httpStatus: initialApiResult.httpStatus,
                businessCode: initialApiResult.businessCode,
                message: initialApiResult.message,
                bodyText: initialApiResult.bodyText,
                isHtmlBody: initialApiResult.isHtmlBody,
                jsonSuccess: initialApiResult.jsonSuccess
            )
            let initialIsOk = (initialState == .success || initialState == .already)
            recorded.append(makeTrace(strategyId: spec.id, result: initialApiResult))

            var effectiveResult = initialApiResult
            var effectiveState = initialState
            var effectiveIsOk = initialIsOk

            let hasBearer = !(account.bearer?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            let hasSession = !(account.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

            if initialState == .authExpired && hasBearer && hasSession && !triedCookieOnlyFallback && !Task.isCancelled {
                triedCookieOnlyFallback = true
                var cookieOnlyAccount = account
                cookieOnlyAccount.bearer = nil

                if let retryApiResult = await performPlan(
                    plan,
                    account: cookieOnlyAccount,
                    variables: variables,
                    endpointReferer: endpointReferer
                ) {
                    let retryState = classify(
                        httpStatus: retryApiResult.httpStatus,
                        businessCode: retryApiResult.businessCode,
                        message: retryApiResult.message,
                        bodyText: retryApiResult.bodyText,
                        isHtmlBody: retryApiResult.isHtmlBody,
                        jsonSuccess: retryApiResult.jsonSuccess
                    )
                    let retryIsOk = (retryState == .success || retryState == .already)
                    recorded.append(makeTrace(strategyId: spec.id, result: retryApiResult))

                    effectiveResult = retryApiResult
                    effectiveState = retryState
                    effectiveIsOk = retryIsOk

                    let cookieAuthAccepted = retryIsOk
                        || ((200...299).contains(retryApiResult.httpStatus)
                            && retryState != .authExpired
                            && retryState != .networkError)
                    if cookieAuthAccepted {
                        account = cookieOnlyAccount
                        credentialsRefreshed = true
                        applyAuthUpdateIfChanged(
                            auth: retryApiResult.authUpdate,
                            markOk: retryIsOk,
                            account: &account,
                            credentialsRefreshed: &credentialsRefreshed
                        )
                    }
                }
            } else {
                // 响应携带新凭据时立即回填，后续重试与策略立刻生效
                applyAuthUpdateIfChanged(
                    auth: initialApiResult.authUpdate,
                    markOk: initialIsOk,
                    account: &account,
                    credentialsRefreshed: &credentialsRefreshed
                )
            }

            finalState = effectiveState
            lastWasHtml = effectiveResult.isHtmlBody
            lastHadJsonMessage = !(effectiveResult.message?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

            let retryableStatus: Bool
            if isDynamic {
                // 动态码不针对 4xx 做慢速重试，仅对传输层/5xx 做一次快速重试
                retryableStatus = effectiveResult.httpStatus == -1
                    || (500...599).contains(effectiveResult.httpStatus)
            } else {
                retryableStatus = effectiveResult.httpStatus == -1
                    || profile.result.retryHttpStatus.contains(effectiveResult.httpStatus)
            }
            let abortImmediately = (effectiveState == .qrExpired || effectiveState == .authExpired)

            if effectiveIsOk || abortImmediately || !retryableStatus || attemptIndex >= effectiveMaxAttempts - 1 || Task.isCancelled {
                break
            }

            attemptIndex += 1
            let shift = min(max(attemptIndex - 1, 0), 10)
            let backoffMs = min(effectiveBaseBackoffMs << shift, isDynamic ? 500 : 30_000)
            if backoffMs > 0 {
                try? await Task.sleep(nanoseconds: backoffMs * 1_000_000)
            }
        }

        return (recorded, finalState, lastWasHtml, lastHadJsonMessage)
    }

    // MARK: - Error Preservation, Host Diagnostics & Variable Building

    private func failurePriority(
        state: SignState,
        strategyId: String?,
        httpStatus: Int?,
        businessCode: Int?,
        isHtmlBody: Bool,
        hasJsonMessage: Bool
    ) -> Int {
        if let code = businessCode,
           [51203, 50070, 50019, 50017, 50004, 50021, 50023, 50003, 50015].contains(code) {
            return 400
        }
        if state == .authExpired {
            return 380
        }
        guard let status = httpStatus else {
            return 50 // 本地安全拦截或跳过的策略，绝不能覆盖真实服务端错误
        }
        if status == 404 || status == 405 {
            return 100
        }
        if isHtmlBody {
            return 100
        }
        if status == -1 || (500...599).contains(status) {
            return 200
        }
        if businessCode != nil || hasJsonMessage || state == .notInClass {
            let isAppScan = (strategyId == Self.appScanStrategyId || strategyId == Self.appScanWebStrategyId)
            return isAppScan ? 360 : 300
        }
        return 120
    }

    private func updateBestFailure(_ best: inout FailureCandidate?, with candidate: FailureCandidate) {
        let trimmed = candidate.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let existing = best {
            if candidate.priority > existing.priority {
                best = candidate
            } else if candidate.priority == existing.priority,
                      existing.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                best = candidate
            }
        } else {
            best = candidate
        }
    }

    private func appendHostMismatchHintIfNeeded(
        message: String,
        account: Account,
        ticket: QrTicket
    ) -> String {
        guard let ticketHost = ticket.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ticketHost.isEmpty else {
            return message
        }
        let normalizedTicketHost = CredentialSanitizer.cleanHost(ticketHost).host
        let normalizedAccountHost = CredentialSanitizer.cleanHost(account.host).host
        guard !normalizedTicketHost.isEmpty,
              !normalizedAccountHost.isEmpty,
              normalizedTicketHost.caseInsensitiveCompare(normalizedAccountHost) != .orderedSame else {
            return message
        }
        if message.contains(normalizedTicketHost) && message.contains(normalizedAccountHost) {
            return message
        }
        return message + "；账号平台(\(normalizedAccountHost))与二维码域名(\(normalizedTicketHost))不一致，请确认账号所属雨课堂版本"
    }

    private func applyAuthUpdateIfChanged(
        auth: AuthUpdate?,
        markOk: Bool,
        account: inout Account,
        credentialsRefreshed: inout Bool
    ) {
        guard let auth, !auth.isEmpty else { return }
        let updated = auth.apply(to: account, markOk: markOk)
        let changed = updated.bearer != account.bearer
            || updated.sessionId != account.sessionId
            || updated.csrfToken != account.csrfToken
        if changed {
            account = updated
            credentialsRefreshed = true
        }
    }

    private func buildVariables(
        account: Account,
        context: LessonContext?,
        ticket: QrTicket,
        spec: StrategySpec
    ) -> [String: TemplateValue] {
        var vars: [String: TemplateValue] = [:]
        // 先填充非空 ticket.params，再写入推断得到的 context.lessonId/classroomId，避免空白参数覆盖上下文
        for (key, value) in ticket.params {
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                vars[key] = .string(value)
            }
        }
        if let lessonId = context?.lessonId, !lessonId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            vars["lessonId"] = .string(lessonId)
        }
        if let classroomId = context?.classroomId, !classroomId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            vars["classroomId"] = .string(classroomId)
        }
        if let checkinId = ticket.checkinId, !checkinId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            vars["checkinId"] = .string(checkinId)
        }
        if !ticket.raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            vars["qrRaw"] = .string(ticket.raw)
        }
        if let userId = account.userId, !userId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            vars["userId"] = .string(userId)
        }
        for (key, value) in spec.vars {
            vars[key] = value
        }
        return vars
    }

    private func findLessonObjects(inResponse jsonObject: [String: TemplateValue]?) -> [LessonContext] {
        guard let jsonObject else { return [] }

        if let dataObj = jsonObject["data"]?.objectValue {
            let fromDataObj = findLessonObjects(in: dataObj)
            if !fromDataObj.isEmpty {
                return fromDataObj
            }
            if let singleLessonId = dataObj.firstNonBlankString("lessonId", "lesson_id") {
                return [
                    LessonContext(
                        lessonId: singleLessonId,
                        classroomId: dataObj.firstNonBlankString("classroomId", "classroom_id"),
                        name: dataObj.firstNonBlankString("courseName", "lessonName", "name", "title")
                    )
                ]
            }
        }

        if let dataArray = jsonObject["data"]?.arrayValue {
            let fromArray = extractLessonContexts(from: dataArray)
            if !fromArray.isEmpty {
                return fromArray
            }
        }

        return findLessonObjects(in: jsonObject)
    }

    private func findLessonObjects(in container: [String: TemplateValue]) -> [LessonContext] {
        let arrayKeys = ["onLessonClassrooms", "classrooms", "lessonList", "lessons"]
        for key in arrayKeys {
            guard let elements = container[key]?.arrayValue else { continue }
            let found = extractLessonContexts(from: elements)
            if !found.isEmpty {
                return found
            }
        }
        return []
    }

    private func extractLessonContexts(from elements: [TemplateValue]) -> [LessonContext] {
        var found: [LessonContext] = []
        for element in elements {
            guard let obj = element.objectValue,
                  let lessonId = obj.firstNonBlankString("lessonId", "lesson_id", "id", "courseId") else {
                continue
            }
            found.append(
                LessonContext(
                    lessonId: lessonId,
                    classroomId: obj.firstNonBlankString("classroomId", "classroom_id"),
                    name: obj.firstNonBlankString("courseName", "lessonName", "name", "title")
                )
            )
        }
        return found
    }

    private func isQrUrlStrategy(_ id: String) -> Bool {
        id == "QR_URL_POST" || id == "QR_URL_GET"
    }

    private func matchesAnyKeyword(_ text: String, keywords: [String]) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()
        return keywords.contains { keyword in
            let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            return !kw.isEmpty && lower.contains(kw.lowercased())
        }
    }
}
