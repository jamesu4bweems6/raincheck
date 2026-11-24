//
//  SignInEngine.swift
//  RainCheck
//
//  多账号签到引擎，与 `core/src/commonMain/kotlin/cn/raincheck/core/SignInEngine.kt` 100% 行为对齐：
//   - `QR_URL_POST`/`QR_URL_GET` 严格执行同源/白名单域名与协议校验，拒绝向任意外部域名携带凭据；
//   - `dryRun = true` 跳过 `discover()` 与一切网络发包，返回 `SignState.DRY_RUN` 且 `refreshedAccount = nil`；
//   - 状态分类优先级与 Kotlin 完全一致：`httpStatus==-1` -> `ERROR` > `401/403` -> `AUTH_REQUIRED`
//     > `alreadyKeywords` -> `ALREADY` > `2xx && isOkCode` -> `SUCCESS` > `authKeywords`(含 HTTP 200)
//     > `expiredKeywords` -> `TICKET_EXPIRED` > `5xx/retryable` -> `ERROR` > `FAILED`；
//   - 5xx/重试中若命中过期或鉴权关键字立即中止重试；
//   - `AsyncSemaphore` 通过 `withTaskCancellationHandler` 原生支持 Task 取消；
//   - 仅在服务端确实下发新凭据且发生变更时才给 `SignResult.refreshedAccount` 赋值（绝不进导出 JSON）。
//

import Foundation

// MARK: - 课堂上下文

struct LessonContext: Hashable, Sendable {
    var lessonId: String
    var classroomId: String?
    var name: String?

    func display() -> String {
        let head = name?.trimmedNonEmpty ?? lessonId
        if let classroomId = classroomId?.trimmedNonEmpty {
            return "\(head) / 课堂 \(classroomId)"
        }
        return head
    }
}

// MARK: - 支持取消的并发信号量

actor AsyncSemaphore {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let limit: Int
    private var available: Int
    private var waiters: [Waiter] = []

    init(limit: Int) {
        let bounded = max(1, min(limit, 64))
        self.limit = bounded
        self.available = bounded
    }

    func acquire() async throws {
        try Task.checkCancellation()
        if available > 0 {
            available -= 1
            return
        }
        let waiterId = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters.append(Waiter(id: waiterId, continuation: continuation))
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id: waiterId)
            }
        }
    }

    func release() {
        while !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.continuation.resume(returning: ())
            return
        }
        available = min(available + 1, limit)
    }

    func availableCount() -> Int {
        available
    }

    private func cancelWaiter(id: UUID) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(throwing: CancellationError())
        }
    }
}

// MARK: - 签到引擎

final class SignInEngine: Sendable {
    private let api: RainCheckApi
    private let profile: ProtocolProfile

    init(api: RainCheckApi, profile: ProtocolProfile) {
        self.api = api
        self.profile = profile
    }

    // MARK: 策略筛选

    func strategiesFor(_ ticket: QrTicket) -> [StrategySpec] {
        let ordered = profile.orderedStrategies(kind: ticket.kind)
        return ordered.filter { spec in
            for key in spec.requires {
                switch key {
                case "lessonId":
                    continue
                case "c":
                    if ticket.dynamicCode?.trimmedNonEmpty == nil { return false }
                case "t":
                    if ticket.timestamp?.trimmedNonEmpty == nil { return false }
                case "s":
                    if ticket.signature?.trimmedNonEmpty == nil { return false }
                default:
                    if ticket.params[key]?.trimmedNonEmpty == nil { return false }
                }
            }
            return true
        }.filter { spec in
            if isQrUrlStrategy(spec.id) {
                return ticket.url?.trimmedNonEmpty != nil
            }
            return spec.endpoint != nil
        }
    }

    // MARK: 上下文推断

    func discover(account: Account, ticket: QrTicket? = nil) async -> LessonContext? {
        var current = account
        var didRefresh = false
        switch await discoverDetailed(account: &current, didRefresh: &didRefresh, ticket: ticket) {
        case .found(let context):
            return context
        default:
            return nil
        }
    }

    // MARK: 单账号签到

    func signIn(
        account: Account,
        ticket: QrTicket,
        options: SignOptions = SignOptions()
    ) async -> SignResult {
        var attempts: [StrategyAttempt] = []
        var current = account
        var didRefresh = false

        if !account.hasCredential {
            return SignResult(
                accountId: account.id,
                label: account.label,
                state: .AUTH_REQUIRED,
                message: "账号没有配置 token / sessionid"
            )
        }

        if ticket.kind == .LOGIN {
            return SignResult(
                accountId: account.id,
                label: account.label,
                state: .NO_CONTEXT,
                message: "这是登录二维码，请先在「账号舱」使用扫码登录"
            )
        }

        var allCandidates = strategiesFor(ticket)
        if let wanted = options.strategyIds?.compactMap({ $0.trimmedNonEmpty }), !wanted.isEmpty {
            let allowed = Set(wanted)
            allCandidates = allCandidates.filter { allowed.contains($0.id) }
        }
        if allCandidates.isEmpty {
            return SignResult(
                accountId: current.id,
                label: current.label,
                state: .NO_CONTEXT,
                message: "profile 没有适用于 \(ticket.kind.rawValue) 的策略",
                lessonId: ticket.lessonId
            )
        }

        // 严格演练模式：零网络请求（跳过 discover()，不返回 refreshedAccount）
        if options.dryRun {
            let dryContext = LessonContext(
                lessonId: ticket.lessonId ?? "<discover>",
                classroomId: ticket.classroomId
            )
            for spec in allCandidates {
                let vars = buildVars(account: current, context: dryContext, ticket: ticket, spec: spec)
                attempts.append(simulateDryRun(account: current, spec: spec, vars: vars, ticket: ticket))
            }
            return SignResult(
                accountId: current.id,
                label: current.label,
                state: .DRY_RUN,
                message: "演练模式：已模拟 \(attempts.count) 条策略，未发起网络请求",
                strategy: allCandidates.first?.id,
                lessonId: ticket.lessonId,
                attempts: attempts,
                refreshedAccount: nil
            )
        }

        // 解析课堂上下文；不吞 401/403 与网络异常
        var discoverFailure: DiscoverOutcome?
        let context: LessonContext?
        if let lessonId = ticket.lessonId?.trimmedNonEmpty {
            context = LessonContext(lessonId: lessonId, classroomId: ticket.classroomId)
        } else {
            let outcome = await discoverDetailed(account: &current, didRefresh: &didRefresh, ticket: ticket)
            switch outcome {
            case .found(let found):
                context = found
            case .authRequired(let message, let attempt):
                return SignResult(
                    accountId: current.id,
                    label: current.label,
                    state: .AUTH_REQUIRED,
                    message: message,
                    attempts: [attempt],
                    refreshedAccount: didRefresh ? current : nil
                )
            case .networkError, .notFound:
                discoverFailure = outcome
                context = nil
            }
        }

        let candidates: [StrategySpec]
        if context != nil {
            candidates = allCandidates
        } else {
            candidates = allCandidates.filter { spec in
                !spec.requires.contains("lessonId")
                    && (!isQrUrlStrategy(spec.id) || (ticket.url.map { profile.isAllowedQrUrl($0, account: current) } ?? false))
            }
        }

        if candidates.isEmpty {
            switch discoverFailure {
            case .networkError(let message, let attempt):
                return SignResult(
                    accountId: current.id,
                    label: current.label,
                    state: .ERROR,
                    message: message,
                    attempts: [attempt],
                    refreshedAccount: didRefresh ? current : nil
                )
            case .notFound(let message, let attempt):
                return SignResult(
                    accountId: current.id,
                    label: current.label,
                    state: .NO_CONTEXT,
                    message: message,
                    attempts: attempt.map { [$0] } ?? [],
                    refreshedAccount: didRefresh ? current : nil
                )
            default:
                return SignResult(
                    accountId: current.id,
                    label: current.label,
                    state: .NO_CONTEXT,
                    message: "无法确定 lessonId，请确认二维码属于进行中的课堂",
                    refreshedAccount: didRefresh ? current : nil
                )
            }
        }

        var lastMessage = "所有策略均被拒绝"
        for spec in candidates {
            if Task.isCancelled {
                return SignResult(
                    accountId: current.id,
                    label: current.label,
                    state: .ERROR,
                    message: "签到已取消",
                    strategy: attempts.last?.strategy,
                    lessonId: context?.lessonId,
                    attempts: attempts,
                    refreshedAccount: didRefresh ? current : nil
                )
            }

            let variables = buildVars(account: current, context: context, ticket: ticket, spec: spec)
            let strategyAttempts = await runStrategy(
                account: &current,
                didRefresh: &didRefresh,
                spec: spec,
                vars: variables,
                context: context,
                ticket: ticket,
                options: options
            )
            attempts.append(contentsOf: strategyAttempts)
            guard let finalAttempt = strategyAttempts.last else { continue }

            let classified = classify(finalAttempt)
            if classified == .SUCCESS || classified == .ALREADY {
                let defaultMsg = classified == .ALREADY ? "已签到" : "签到成功"
                return SignResult(
                    accountId: current.id,
                    label: current.label,
                    state: classified,
                    message: finalAttempt.message?.trimmedNonEmpty ?? defaultMsg,
                    strategy: spec.id,
                    lessonId: context?.lessonId,
                    attempts: attempts,
                    refreshedAccount: didRefresh ? current : nil
                )
            }

            lastMessage = finalAttempt.message?.trimmedNonEmpty ?? lastMessage
            if classified == .AUTH_REQUIRED {
                return SignResult(
                    accountId: current.id,
                    label: current.label,
                    state: .AUTH_REQUIRED,
                    message: lastMessage,
                    strategy: spec.id,
                    lessonId: context?.lessonId,
                    attempts: attempts,
                    refreshedAccount: didRefresh ? current : nil
                )
            }
            if classified == .TICKET_EXPIRED && options.stopWhenTicketExpired {
                return SignResult(
                    accountId: current.id,
                    label: current.label,
                    state: .TICKET_EXPIRED,
                    message: lastMessage,
                    strategy: spec.id,
                    lessonId: context?.lessonId,
                    attempts: attempts,
                    refreshedAccount: didRefresh ? current : nil
                )
            }
        }

        let networkAttempts = attempts.filter { $0.httpStatus != nil }
        let finalState: SignState
        if !networkAttempts.isEmpty && networkAttempts.allSatisfy({ classify($0) == .ERROR }) {
            finalState = .ERROR
        } else {
            finalState = attempts.last.map { classify($0) } ?? .FAILED
        }
        let safeFinalState: SignState = (finalState == .SUCCESS || finalState == .ALREADY) ? .FAILED : finalState
        return SignResult(
            accountId: current.id,
            label: current.label,
            state: safeFinalState,
            message: lastMessage,
            strategy: attempts.last?.strategy,
            lessonId: context?.lessonId,
            attempts: attempts,
            refreshedAccount: didRefresh ? current : nil
        )
    }

    // MARK: 多账号并发

    func signInAll(
        accounts: [Account],
        ticket: QrTicket,
        options: SignOptions = SignOptions(),
        onProgress: (@Sendable (SignResult) -> Void)? = nil
    ) async -> SignBatchReport {
        let started = TimeUtil.nowMillis()
        let targets = accounts.filter { $0.enabled }
        if targets.isEmpty {
            return SignBatchReport(results: [], startedAt: started, finishedAt: started, ticket: ticket)
        }

        let semaphore = AsyncSemaphore(limit: options.concurrency)
        var slots = [SignResult?](repeating: nil, count: targets.count)

        await withTaskGroup(of: (Int, SignResult).self) { group in
            for (index, account) in targets.enumerated() {
                let stagger = options.staggerMs
                group.addTask { [self] in
                    if stagger > 0 && index > 0 {
                        let delayMs = min(Int64(index) * stagger, 60_000)
                        do {
                            try await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                        } catch {
                            return (index, SignResult(
                                accountId: account.id,
                                label: account.label,
                                state: .ERROR,
                                message: "签到已取消"
                            ))
                        }
                    }
                    do {
                        try await semaphore.acquire()
                    } catch {
                        return (index, SignResult(
                            accountId: account.id,
                            label: account.label,
                            state: .ERROR,
                            message: "签到已取消"
                        ))
                    }
                    let result = await self.signIn(account: account, ticket: ticket, options: options)
                    await semaphore.release()
                    return (index, result)
                }
            }
            for await (index, result) in group {
                slots[index] = result
                onProgress?(result)
            }
        }

        let results = slots.compactMap { $0 }
        return SignBatchReport(
            results: results,
            startedAt: started,
            finishedAt: TimeUtil.nowMillis(),
            ticket: ticket
        )
    }

    // MARK: 分类器（与 Kotlin `SignInEngine.kt` 100% 对齐）

    func classify(_ attempt: StrategyAttempt) -> SignState {
        let status = attempt.httpStatus
        if status == -1 { return .ERROR }
        if status == 401 || status == 403 { return .AUTH_REQUIRED }

        let text = attempt.message?.trimmedNonEmpty ?? (attempt.responseBody ?? "")
        let isServerOrRetryable = status.map { $0 >= 500 || profile.result.retryHttpStatus.contains($0) } ?? false

        if status != nil && !isServerOrRetryable && matchesAnyKeyword(text, keywords: profile.result.alreadyKeywords) {
            return .ALREADY
        }
        if let status, (200...299).contains(status), profile.result.isOkCode(attempt.code) {
            return .SUCCESS
        }
        if matchesAnyKeyword(text, keywords: profile.result.authKeywords) {
            return .AUTH_REQUIRED
        }
        if matchesAnyKeyword(text, keywords: profile.result.expiredKeywords) {
            return .TICKET_EXPIRED
        }
        if isServerOrRetryable {
            return .ERROR
        }
        return .FAILED
    }

    // MARK: 内部辅助

    private enum DiscoverOutcome {
        case found(LessonContext)
        case authRequired(String, StrategyAttempt)
        case networkError(String, StrategyAttempt)
        case notFound(String, StrategyAttempt?)
    }

    private struct RequestPlan {
        let method: String
        let url: String
        let body: JSONValue?
    }

    private enum PlanBuildResult {
        case ready(RequestPlan)
        case rejected(String)
    }

    private func discoverDetailed(
        account: inout Account,
        didRefresh: inout Bool,
        ticket: QrTicket?
    ) async -> DiscoverOutcome {
        let active = await api.call(account: account, endpointName: "activeLesson")
        applyAuthUpdateIfChanged(account: &account, didRefresh: &didRefresh, auth: active.auth, markOk: active.ok)

        let endpointPath = profile.endpoints["activeLesson"]?.path ?? "/api/v3/classroom/on-lesson-upcoming-exam"
        let attempt = StrategyAttempt(
            strategy: "DISCOVER_ACTIVE_LESSON",
            httpStatus: active.httpStatus,
            code: active.code,
            message: active.message?.trimmedNonEmpty ?? String(active.body.prefix(160)),
            ok: active.ok,
            requestLine: "GET \(account.scheme)://\(account.host)\(endpointPath)",
            responseBody: String(active.body.prefix(2000)),
            elapsedMs: active.elapsedMs
        )

        if active.httpStatus == -1 {
            return .networkError("查询进行中课堂网络异常: \(String(active.body.prefix(120)))", attempt)
        }
        if active.httpStatus == 401 || active.httpStatus == 403 {
            return .authRequired(
                active.message?.trimmedNonEmpty ?? "查询课堂时鉴权失败 (HTTP \(active.httpStatus))",
                attempt
            )
        }
        let rawMsg = active.message?.trimmedNonEmpty ?? active.body
        if !active.ok && matchesAnyKeyword(rawMsg, keywords: profile.result.authKeywords) {
            return .authRequired(active.message?.trimmedNonEmpty ?? "查询课堂时会话失效", attempt)
        }
        if !active.ok && (active.httpStatus >= 500 || profile.result.retryHttpStatus.contains(active.httpStatus)) {
            return .networkError(
                active.message?.trimmedNonEmpty ?? "查询进行中课堂服务端异常 (HTTP \(active.httpStatus))",
                attempt
            )
        }

        if active.ok, let data = active.data() {
            let lessons = findLessonObjects(data)
            if let classroomId = ticket?.classroomId?.trimmedNonEmpty,
               let matched = lessons.first(where: { $0.classroomId == classroomId }) {
                return .found(matched)
            }
            if let first = lessons.first {
                return .found(first)
            }
        }
        return .notFound("无法确定 lessonId，请确认二维码属于进行中的课堂", attempt)
    }

    private func buildRequestPlan(
        account: Account,
        spec: StrategySpec,
        vars: [String: JSONValue],
        ticket: QrTicket
    ) -> PlanBuildResult {
        let base = "\(account.scheme)://\(account.host)"
        if isQrUrlStrategy(spec.id) {
            guard let rawUrl = ticket.url?.trimmedNonEmpty else {
                return .rejected("二维码不是 URL，跳过")
            }
            if let securityError = profile.validateQrUrl(rawUrl, account: account) {
                return .rejected("安全拦截：拒绝向非白名单地址发送凭据（\(securityError)）")
            }
            let method = spec.id == "QR_URL_GET" ? "GET" : "POST"
            return .ready(RequestPlan(method: method, url: rawUrl, body: method == "GET" ? nil : qrBody(ticket)))
        }
        guard let endpointName = spec.endpoint, let endpoint = profile.endpoints[endpointName] else {
            return .rejected("profile 缺少 endpoint")
        }
        let path = Template.renderPath(endpoint.path, vars: vars)
        let url = api.buildUrl(base: base, path: path, query: Template.renderMap(endpoint.query, vars: vars))
        let body = endpoint.body.map { Template.renderBody($0, vars: vars) }
        return .ready(RequestPlan(method: endpoint.method, url: url, body: body))
    }

    private func simulateDryRun(
        account: Account,
        spec: StrategySpec,
        vars: [String: JSONValue],
        ticket: QrTicket
    ) -> StrategyAttempt {
        switch buildRequestPlan(account: account, spec: spec, vars: vars, ticket: ticket) {
        case .rejected(let reason):
            return StrategyAttempt(strategy: spec.id, message: reason, ok: false)
        case .ready(let plan):
            return StrategyAttempt(
                strategy: spec.id,
                message: "演练模式，未发送",
                ok: false,
                requestLine: "\(plan.method) \(plan.url)",
                requestBody: plan.body?.serialized()
            )
        }
    }

    private func runStrategy(
        account: inout Account,
        didRefresh: inout Bool,
        spec: StrategySpec,
        vars: [String: JSONValue],
        context: LessonContext?,
        ticket: QrTicket,
        options: SignOptions
    ) async -> [StrategyAttempt] {
        let plan: RequestPlan
        switch buildRequestPlan(account: account, spec: spec, vars: vars, ticket: ticket) {
        case .rejected(let reason):
            return [StrategyAttempt(strategy: spec.id, message: reason, ok: false)]
        case .ready(let readyPlan):
            plan = readyPlan
        }

        let maxAttempts = max(1, options.maxAttemptsPerStrategy)
        var recorded: [StrategyAttempt] = []
        var attemptIndex = 0

        while attemptIndex < maxAttempts {
            let referer = RainCheckApi.referer(account: account, classroomId: context?.classroomId)
            let result = await api.raw(
                account: account,
                method: plan.method,
                url: plan.url,
                body: plan.body,
                referer: referer
            )

            var attempt = StrategyAttempt(
                strategy: spec.id,
                httpStatus: result.httpStatus,
                code: result.code,
                message: result.message?.trimmedNonEmpty ?? String(result.body.prefix(160)),
                ok: false,
                requestLine: "\(plan.method) \(plan.url)",
                requestBody: plan.body?.serialized(),
                responseBody: String(result.body.prefix(2000)),
                elapsedMs: result.elapsedMs
            )
            let state = classify(attempt)
            let isOk = state == .SUCCESS || state == .ALREADY
            attempt.ok = isOk
            recorded.append(attempt)

            applyAuthUpdateIfChanged(account: &account, didRefresh: &didRefresh, auth: result.auth, markOk: isOk)

            let retryableStatus = result.httpStatus == -1 || profile.result.retryHttpStatus.contains(result.httpStatus)
            let abortImmediately = state == .TICKET_EXPIRED || state == .AUTH_REQUIRED
            if isOk || abortImmediately || !retryableStatus || attemptIndex >= maxAttempts - 1 {
                break
            }

            attemptIndex += 1
            let shift = min(max(attemptIndex - 1, 0), 10)
            let backoffMs = min(options.baseBackoffMs * Int64(1 << shift), 30_000)
            if backoffMs > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(backoffMs) * 1_000_000)
                } catch {
                    break
                }
            }
        }
        return recorded
    }

    private func applyAuthUpdateIfChanged(
        account: inout Account,
        didRefresh: inout Bool,
        auth: AuthUpdate?,
        markOk: Bool
    ) {
        guard let auth, !auth.isEmpty else { return }
        let updated = auth.applyTo(account, markOk: markOk)
        let changed = updated.bearer != account.bearer
            || updated.sessionId != account.sessionId
            || updated.csrfToken != account.csrfToken
        if changed {
            account = updated
            didRefresh = true
        }
    }

    private func qrBody(_ ticket: QrTicket) -> JSONValue {
        var map: [String: JSONValue] = [:]
        for (key, value) in ticket.params {
            map[key] = .string(value)
        }
        return .object(map)
    }

    private func buildVars(
        account: Account,
        context: LessonContext?,
        ticket: QrTicket,
        spec: StrategySpec
    ) -> [String: JSONValue] {
        var vars: [String: JSONValue] = [:]
        if let lessonId = context?.lessonId.trimmedNonEmpty {
            vars["lessonId"] = .string(lessonId)
        }
        if let classroomId = context?.classroomId?.trimmedNonEmpty {
            vars["classroomId"] = .string(classroomId)
        }
        if let checkinId = ticket.checkinId?.trimmedNonEmpty {
            vars["checkinId"] = .string(checkinId)
        }
        for (key, value) in ticket.params {
            vars[key] = .string(value)
        }
        if let userId = account.userId?.trimmedNonEmpty {
            vars["userId"] = .string(userId)
        }
        for (key, value) in spec.vars {
            vars[key] = value
        }
        return vars
    }

    private func matchesAnyKeyword(_ text: String, keywords: [String]) -> Bool {
        guard !text.trimmed.isEmpty else { return false }
        let lower = text.lowercased()
        return keywords.contains { kw in
            guard let clean = kw.trimmedNonEmpty else { return false }
            return lower.contains(clean.lowercased())
        }
    }

    private func isQrUrlStrategy(_ id: String) -> Bool {
        id == "QR_URL_POST" || id == "QR_URL_GET"
    }

    private func findLessonObjects(_ data: [String: JSONValue]) -> [LessonContext] {
        let keys = ["onLessonClassrooms", "classrooms", "lessonList", "lessons"]
        for key in keys {
            guard let array = data[key]?.arrayValue else { continue }
            var parsed: [LessonContext] = []
            for element in array {
                guard let object = element.objectValue,
                      let lessonId = JSONAssist.firstString(object, ["lessonId", "lesson_id", "id", "courseId"]) else {
                    continue
                }
                let classroomId = JSONAssist.firstString(object, ["classroomId", "classroom_id"])
                let name = JSONAssist.firstString(object, ["courseName", "lessonName", "name", "title"])
                parsed.append(LessonContext(lessonId: lessonId, classroomId: classroomId, name: name))
            }
            if !parsed.isEmpty {
                return parsed
            }
        }
        return []
    }
}
