import Dispatch
import Foundation

/// 一次签到推断得到的课堂上下文。
struct LessonContext: Hashable, Sendable {
    let lessonId: String
    let classroomId: String?
    let name: String?
}

/// 多账号多策略签到编排引擎（与 Kotlin `SignInEngine.kt` 保持 100% 行为与安全护栏一致）。
final class CheckInOrchestrator: Sendable {
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
                    return true // 允许运行期由 activeLesson 发现
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

    /// 单账号签到：按策略链顺序执行，命中即停，支持会话刷新回填与同源安全护栏。
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

        let allCandidates = applicableStrategies(for: ticket)
        if allCandidates.isEmpty {
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

        // 严格演练模式：绝对不发起任何网络请求（包含跳过 activeLesson 探测）
        if dryRun {
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
                strategyId: allCandidates.first?.id,
                httpStatus: nil,
                message: "演练模式：已模拟 \(traces.count) 条策略，未发起网络请求",
                elapsedMs: max(0, RainCheckTime.nowMillis() - startedMs),
                attempts: traces,
                timestampMs: RainCheckTime.nowMillis(),
                refreshedAccount: nil
            )
        }

        // 解析课堂上下文；缺失 lessonId 时尝试从 activeLesson 推断，绝不吞掉 401/403 与网络异常
        var discoverFailure: DiscoverOutcome?
        let context: LessonContext?
        if let lessonId = ticket.lessonId {
            context = LessonContext(lessonId: lessonId, classroomId: ticket.classroomId, name: nil)
        } else {
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
                    message: message,
                    elapsedMs: max(0, RainCheckTime.nowMillis() - startedMs),
                    attempts: traces,
                    timestampMs: RainCheckTime.nowMillis(),
                    refreshedAccount: credentialsRefreshed ? currentAccount : nil
                )
            case .networkError(_, let discoverTraces):
                traces.append(contentsOf: discoverTraces)
                discoverFailure = outcome
                context = nil
            case .notFound(_, let discoverTraces):
                traces.append(contentsOf: discoverTraces)
                discoverFailure = outcome
                context = nil
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
            let finalState: SignState
            let finalMessage: String
            let lastStatus: Int?
            switch discoverFailure {
            case .networkError(let msg, let discoverTraces):
                finalState = .networkError
                finalMessage = msg
                lastStatus = discoverTraces.last?.httpStatus
            case .notFound(let msg, let discoverTraces):
                finalState = .notInClass
                finalMessage = msg
                lastStatus = discoverTraces.last?.httpStatus
            default:
                finalState = .notInClass
                finalMessage = "无法确定 lessonId，请确认二维码属于进行中的课堂"
                lastStatus = nil
            }
            return SignResult(
                accountId: currentAccount.id,
                accountLabel: currentAccount.label,
                host: currentAccount.host,
                state: finalState,
                strategyId: traces.last?.strategyId,
                httpStatus: lastStatus,
                message: finalMessage,
                elapsedMs: max(0, RainCheckTime.nowMillis() - startedMs),
                attempts: traces,
                timestampMs: RainCheckTime.nowMillis(),
                refreshedAccount: credentialsRefreshed ? currentAccount : nil
            )
        }

        var lastMessage = "所有策略均被拒绝"
        var lastState: SignState = .failed
        var lastStrategyId: String?
        var lastHttpStatus: Int?

        for spec in candidates {
            if Task.isCancelled {
                return SignResult(
                    accountId: currentAccount.id,
                    accountLabel: currentAccount.label,
                    host: currentAccount.host,
                    state: .failed,
                    strategyId: lastStrategyId,
                    httpStatus: lastHttpStatus,
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
            lastState = classified
            lastStrategyId = spec.id
            lastHttpStatus = finalTrace.httpStatus

            if !finalTrace.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lastMessage = finalTrace.message
            }

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
                    message: effectiveMsg,
                    elapsedMs: max(0, RainCheckTime.nowMillis() - startedMs),
                    attempts: traces,
                    timestampMs: RainCheckTime.nowMillis(),
                    refreshedAccount: credentialsRefreshed ? currentAccount : nil
                )
            }

            if classified == .authExpired {
                return SignResult(
                    accountId: currentAccount.id,
                    accountLabel: currentAccount.label,
                    host: currentAccount.host,
                    state: .authExpired,
                    strategyId: spec.id,
                    httpStatus: finalTrace.httpStatus,
                    message: lastMessage,
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
                    message: lastMessage,
                    elapsedMs: max(0, RainCheckTime.nowMillis() - startedMs),
                    attempts: traces,
                    timestampMs: RainCheckTime.nowMillis(),
                    refreshedAccount: credentialsRefreshed ? currentAccount : nil
                )
            }
        }

        let networkTraces = traces.filter {
            $0.httpStatus != nil && $0.strategyId != "DISCOVER_ACTIVE_LESSON"
        }
        let resolvedState: SignState
        if !networkTraces.isEmpty && networkTraces.allSatisfy({ classify(httpStatus: $0.httpStatus, businessCode: $0.businessCode, message: $0.message, bodyText: "") == .networkError }) {
            resolvedState = .networkError
        } else if lastState == .success || lastState == .already {
            resolvedState = .failed
        } else {
            resolvedState = lastState
        }

        return SignResult(
            accountId: currentAccount.id,
            accountLabel: currentAccount.label,
            host: currentAccount.host,
            state: resolvedState,
            strategyId: lastStrategyId ?? traces.last?.strategyId,
            httpStatus: lastHttpStatus,
            message: lastMessage,
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

    // MARK: - Classification

    /// 严格按 Kotlin `SignInEngine.classify` 优先级归类结果状态。
    func classify(
        httpStatus: Int?,
        businessCode: Int?,
        message: String?,
        bodyText: String
    ) -> SignState {
        if httpStatus == -1 {
            return .networkError
        }
        if httpStatus == 401 || httpStatus == 403 {
            return .authExpired
        }

        let trimmedMsg = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = trimmedMsg.isEmpty ? bodyText : trimmedMsg
        let isServerOrRetryable: Bool
        if let status = httpStatus {
            isServerOrRetryable = status >= 500 || profile.result.retryHttpStatus.contains(status)
        } else {
            isServerOrRetryable = false
        }

        if httpStatus != nil && !isServerOrRetryable && matchesAnyKeyword(text, keywords: profile.result.alreadyKeywords) {
            return .already
        }
        if let status = httpStatus, (200...299).contains(status), profile.result.isOkCode(businessCode) {
            return .success
        }
        if businessCode == 401 {
            return .authExpired
        }
        if matchesAnyKeyword(text, keywords: profile.result.authKeywords) {
            return .authExpired
        }
        if matchesAnyKeyword(text, keywords: profile.result.expiredKeywords) {
            return .qrExpired
        }
        if isServerOrRetryable {
            return .networkError
        }
        if matchesAnyKeyword(text, keywords: ["未加入", "不在课堂", "不在该课", "非本班"]) {
            return .notInClass
        }
        return .failed
    }

    // MARK: - Discovery & Strategy Execution

    private enum DiscoverOutcome {
        case found(LessonContext, [AttemptTrace])
        case authExpired(String, [AttemptTrace])
        case networkError(String, [AttemptTrace])
        case notFound(String, [AttemptTrace])
    }

    private func isDiscoverAuthFailure(_ result: ApiCallResult) -> Bool {
        if result.httpStatus == 401 || result.httpStatus == 403 {
            return true
        }
        if !result.ok && result.businessCode == 401 {
            return true
        }
        let rawText = result.message ?? result.bodyText
        if !result.ok && matchesAnyKeyword(rawText, keywords: profile.result.authKeywords) {
            return true
        }
        return false
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
            message: result.message ?? String(result.bodyText.prefix(160)),
            elapsedMs: result.elapsedMs
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
        if active.httpStatus == 401 || active.httpStatus == 403 {
            return .authExpired(
                active.message ?? "查询课堂时鉴权失败 (HTTP \(active.httpStatus))",
                recorded
            )
        }
        let rawText = active.message ?? active.bodyText
        if !active.ok && (active.businessCode == 401 || matchesAnyKeyword(rawText, keywords: profile.result.authKeywords)) {
            return .authExpired(active.message ?? "查询课堂时会话失效", recorded)
        }
        if !active.ok && (active.httpStatus >= 500 || profile.result.retryHttpStatus.contains(active.httpStatus)) {
            return .networkError(
                active.message ?? "查询进行中课堂服务端异常 (HTTP \(active.httpStatus))",
                recorded
            )
        }

        if active.ok, let data = active.dataObject {
            let lessons = findLessonObjects(in: data)
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
        referer: String
    ) async -> ApiCallResult? {
        switch plan {
        case .endpointPlan(let endpointKey, _, _):
            return await client.executeEndpoint(
                endpointKey,
                account: account,
                variables: variables,
                extraCookies: [:],
                referer: referer,
                extraHeaders: [:]
            )
        case .directUrlPlan(let method, let url, let body):
            return await client.callDirectUrl(
                url,
                method: method,
                account: account,
                body: body,
                referer: referer
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
    ) async -> (traces: [AttemptTrace], finalState: SignState) {
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
            return ([trace], .failed)
        }

        var recorded: [AttemptTrace] = []
        var finalState: SignState = .failed
        var attemptIndex = 0
        var triedCookieOnlyFallback = false

        while attemptIndex < maxAttemptsPerStrategy {
            if Task.isCancelled {
                break
            }

            let base = "\(account.scheme)://\(account.host)"
            let referer: String
            if let classroomId = context?.classroomId, !classroomId.isEmpty {
                referer = "\(base)/v2/web/studentLog/\(classroomId)"
            } else {
                referer = "\(base)/v2/web/index"
            }

            guard let initialApiResult = await performPlan(
                plan,
                account: account,
                variables: variables,
                referer: referer
            ) else {
                return (recorded, .failed)
            }

            let initialState = classify(
                httpStatus: initialApiResult.httpStatus,
                businessCode: initialApiResult.businessCode,
                message: initialApiResult.message,
                bodyText: initialApiResult.bodyText
            )
            let initialIsOk = (initialState == .success || initialState == .already)

            let initialTrace = AttemptTrace(
                strategyId: spec.id,
                method: initialApiResult.requestMethod,
                url: initialApiResult.requestUrl,
                httpStatus: initialApiResult.httpStatus,
                businessCode: initialApiResult.businessCode,
                message: initialApiResult.message ?? String(initialApiResult.bodyText.prefix(160)),
                elapsedMs: initialApiResult.elapsedMs
            )
            recorded.append(initialTrace)

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
                    referer: referer
                ) {
                    let retryState = classify(
                        httpStatus: retryApiResult.httpStatus,
                        businessCode: retryApiResult.businessCode,
                        message: retryApiResult.message,
                        bodyText: retryApiResult.bodyText
                    )
                    let retryIsOk = (retryState == .success || retryState == .already)
                    let retryTrace = AttemptTrace(
                        strategyId: spec.id,
                        method: retryApiResult.requestMethod,
                        url: retryApiResult.requestUrl,
                        httpStatus: retryApiResult.httpStatus,
                        businessCode: retryApiResult.businessCode,
                        message: retryApiResult.message ?? String(retryApiResult.bodyText.prefix(160)),
                        elapsedMs: retryApiResult.elapsedMs
                    )
                    recorded.append(retryTrace)

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

            let retryableStatus = effectiveResult.httpStatus == -1
                || profile.result.retryHttpStatus.contains(effectiveResult.httpStatus)
            let abortImmediately = (effectiveState == .qrExpired || effectiveState == .authExpired)

            if effectiveIsOk || abortImmediately || !retryableStatus || attemptIndex >= maxAttemptsPerStrategy - 1 || Task.isCancelled {
                break
            }

            attemptIndex += 1
            let shift = min(max(attemptIndex - 1, 0), 10)
            let backoffMs = min(baseBackoffMs << shift, 30_000)
            if backoffMs > 0 {
                try? await Task.sleep(nanoseconds: backoffMs * 1_000_000)
            }
        }

        return (recorded, finalState)
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
        if let lessonId = context?.lessonId {
            vars["lessonId"] = .string(lessonId)
        }
        if let classroomId = context?.classroomId {
            vars["classroomId"] = .string(classroomId)
        }
        if let checkinId = ticket.checkinId {
            vars["checkinId"] = .string(checkinId)
        }
        for (key, value) in ticket.params {
            vars[key] = .string(value)
        }
        if let userId = account.userId {
            vars["userId"] = .string(userId)
        }
        for (key, value) in spec.vars {
            vars[key] = value
        }
        return vars
    }

    private func findLessonObjects(in data: [String: TemplateValue]) -> [LessonContext] {
        let arrayKeys = ["onLessonClassrooms", "classrooms", "lessonList", "lessons"]
        for key in arrayKeys {
            guard let elements = data[key]?.arrayValue else { continue }
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
            if !found.isEmpty {
                return found
            }
        }
        return []
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
