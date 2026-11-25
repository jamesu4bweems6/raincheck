import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct CheckInView: View {
    @ObservedObject var store: AppStore
    @Environment(\.colorScheme) private var colorScheme

    @State private var showScanner = false
    @State private var pendingManualPasteAfterScanner = false
    @State private var showManualInput = false
    @State private var manualInputText = ""
    @State private var expandedResultIds: Set<String> = []

    private var enabledAccounts: [Account] {
        store.accounts.filter(\.enabled)
    }

    private var selectedEnabledCount: Int {
        store.selectedEnabledAccounts.count
    }

    private var allEnabledSelected: Bool {
        !enabledAccounts.isEmpty && selectedEnabledCount == enabledAccounts.count
    }

    private var canStartCheckIn: Bool {
        guard let ticket = store.currentTicket, ticket.kind != .login else { return false }
        return selectedEnabledCount > 0 && !store.isCheckingIn
    }

    private var latestSucceededCount: Int {
        store.results.filter { $0.state.isSuccessLike }.count
    }

    private var latestFailedCount: Int {
        store.results.filter { $0.state.isFailureLike }.count
    }

    private var latestFailedResults: [SignResult] {
        store.results.filter { $0.state.isFailureLike }
    }

    private var orderedLatestResults: [SignResult] {
        let failed = store.results.filter { $0.state.isFailureLike }
        let others = store.results.filter { !$0.state.isFailureLike }
        return failed + others
    }

    private var latestIsDryRunBatch: Bool {
        !store.results.isEmpty && store.results.allSatisfy { $0.state.isDryRun }
    }

    private func shouldShowResultSummary(for ticket: QrTicket) -> Bool {
        !store.isCheckingIn && !store.results.isEmpty && store.lastBatchTicket?.raw == ticket.raw
    }

    private var scanHeroSubtitle: String {
        if selectedEnabledCount > 0 {
            return store.dryRun
                ? "支持动态签到码，扫码或相册识码后将自动为已选的 \(selectedEnabledCount) 个账号执行演练。"
                : "支持动态签到码，扫码或相册识码后将立即为已选的 \(selectedEnabledCount) 个账号自动签到。"
        }
        return "请先在上方勾选至少一个要签到的账号（支持多选），扫码后将自动执行签到。"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidCanvas()

                ScrollView {
                    VStack(alignment: .leading, spacing: LiquidMetrics.sectionSpacing) {
                        if store.dryRun {
                            dryRunBanner
                        }

                        accountSelectionSection

                        scanHeroCard

                        if store.isCheckingIn {
                            checkInProgressCard
                        }

                        if let ticket = store.currentTicket {
                            ticketSummaryCard(ticket)

                            if !store.isCheckingIn && canStartCheckIn {
                                manualRerunButton
                            }
                        }
                    }
                    .padding(.horizontal, LiquidMetrics.pageHorizontalPadding)
                    .padding(.top, 14)
                    .padding(.bottom, LiquidMetrics.scrollBottomPadding)
                }
            }
            .navigationTitle("签到")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Toggle(isOn: $store.dryRun) {
                            Label("演练模式", systemImage: "testtube.2")
                        }
                        .disabled(store.isCheckingIn)

                        Button {
                            manualInputText = ""
                            showManualInput = true
                        } label: {
                            Label("手动输入链接", systemImage: "keyboard")
                        }
                        .disabled(store.isCheckingIn)

                        if store.currentTicket != nil {
                            Button {
                                store.clearTicket()
                            } label: {
                                Label("清除当前二维码", systemImage: "xmark.circle")
                            }
                            .disabled(store.isCheckingIn)
                        }
                    } label: {
                        Image(systemName: store.dryRun ? "testtube.2" : "ellipsis")
                            .font(.body.weight(.medium))
                            .foregroundStyle(store.dryRun ? LiquidPalette.accent : LiquidPalette.primaryText)
                            .accessibilityLabel("更多选项")
                    }
                }
            }
            .fullScreenCover(
                isPresented: $showScanner,
                onDismiss: {
                    if pendingManualPasteAfterScanner {
                        pendingManualPasteAfterScanner = false
                        handlePasteAction()
                    }
                }
            ) {
                CameraScannerSheet(
                    selectedAccountCount: selectedEnabledCount,
                    isDryRun: store.dryRun,
                    onScanned: { raw in
                        store.applyQrInput(raw, autoStartCheckIn: true)
                    },
                    onManualPaste: {
                        pendingManualPasteAfterScanner = true
                    }
                )
            }
            .sheet(isPresented: $showManualInput) {
                ManualLinkInputSheet(
                    text: $manualInputText,
                    selectedAccountCount: selectedEnabledCount,
                    isDryRun: store.dryRun,
                    onConfirm: { raw in
                        store.applyQrInput(raw, autoStartCheckIn: true)
                    }
                )
            }
        }
    }

    private var dryRunBanner: some View {
        HStack(spacing: 10) {
            LiquidStatusChip(symbol: "testtube.2", text: "演练模式 · 不发送网络请求", emphasized: true)
            Spacer(minLength: 8)
            Button {
                store.dryRun = false
            } label: {
                Text("关闭")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(LiquidPalette.primaryText)
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .frame(minWidth: 68, minHeight: 32)
                    .background(LiquidPalette.subtleSurface(colorScheme), in: Capsule())
                    .overlay {
                        Capsule()
                            .strokeBorder(LiquidPalette.hairline(colorScheme), lineWidth: 0.75)
                            .allowsHitTesting(false)
                    }
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(store.isCheckingIn)
            .opacity(store.isCheckingIn ? 0.5 : 1.0)
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            LiquidPalette.elevatedSurface(colorScheme),
            in: RoundedRectangle(cornerRadius: LiquidMetrics.cornerRadiusControl + 4, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: LiquidMetrics.cornerRadiusControl + 4, style: .continuous)
                .strokeBorder(LiquidPalette.hairline(colorScheme), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
    }

    private var scanHeroCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(LiquidPalette.accent)
                    .frame(width: 42, height: 42)
                    .background(
                        LiquidPalette.accent.opacity(colorScheme == .dark ? 0.16 : 0.10),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(
                                LiquidPalette.accent.opacity(colorScheme == .dark ? 0.28 : 0.20),
                                lineWidth: 0.75
                            )
                            .allowsHitTesting(false)
                    }

                VStack(alignment: .leading, spacing: 4) {
                    Text(store.dryRun ? "2. 扫码自动演练" : "2. 扫码自动签到")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(LiquidPalette.primaryText)

                    Text(scanHeroSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(LiquidPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: 10) {
                LiquidGlassGroup(spacing: 10) {
                    HStack(spacing: 10) {
                        Button {
                            showScanner = true
                        } label: {
                            Label(
                                store.dryRun ? "扫码自动演练" : "扫码自动签到",
                                systemImage: "qrcode.viewfinder"
                            )
                            .minimumScaleFactor(0.76)
                        }
                        .liquidPrimaryButtonStyle(
                            minWidth: nil,
                            horizontalPadding: 14,
                            fullWidth: true
                        )
                        .disabled(selectedEnabledCount == 0 || store.isCheckingIn)

                        Button {
                            handlePasteAction()
                        } label: {
                            Label("粘贴链接", systemImage: "doc.on.clipboard")
                        }
                        .liquidSecondaryButtonStyle(
                            minWidth: nil,
                            horizontalPadding: 14,
                            fullWidth: true
                        )
                        .disabled(store.isCheckingIn)
                    }
                }

                if selectedEnabledCount == 0 && !store.isCheckingIn {
                    Text("请先在上方选择至少一个已启用账号")
                        .font(.footnote)
                        .foregroundStyle(LiquidPalette.secondaryText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(LiquidMetrics.cardPadding)
        .liquidGlassCard()
    }

    private func ticketSummaryCard(_ ticket: QrTicket) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 8) {
                LiquidStatusChip(
                    symbol: ticketSymbol(for: ticket.kind),
                    text: ticket.kind.displayTitle,
                    emphasized: ticket.kind == .dynamicCheckin
                )

                Spacer(minLength: 8)

                Button {
                    store.clearTicket()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LiquidPalette.secondaryText)
                        .frame(width: 32, height: 32)
                        .background(LiquidPalette.subtleSurface(colorScheme), in: Circle())
                        .overlay {
                            Circle()
                                .strokeBorder(LiquidPalette.hairline(colorScheme), lineWidth: 0.75)
                                .allowsHitTesting(false)
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(store.isCheckingIn)
                .opacity(store.isCheckingIn ? 0.45 : 1.0)
                .accessibilityLabel("清除当前二维码")
            }

            if ticket.kind == .dynamicCheckin {
                if let issuedAt = ticket.issuedAtEpochSeconds {
                    dynamicCountdownView(issuedAt: issuedAt)
                } else {
                    dynamicFreshnessHintView
                }
            }

            Divider()
                .overlay(LiquidPalette.hairline(colorScheme))

            VStack(alignment: .leading, spacing: 8) {
                if let host = ticket.host, !host.isEmpty {
                    ticketMetaRow(
                        label: "平台",
                        value: "\(LiquidPalette.editionDisplayName(forHost: host)) · \(host)"
                    )
                }

                if let lessonId = ticket.lessonId, !lessonId.isEmpty {
                    ticketMetaRow(label: "课堂 ID", value: lessonId, monospaced: true)
                } else {
                    Text(ticket.summary())
                        .font(.footnote)
                        .foregroundStyle(LiquidPalette.secondaryText)
                        .lineLimit(2)
                }

                if let checkinId = ticket.checkinId, !checkinId.isEmpty {
                    ticketMetaRow(label: "签到 ID", value: checkinId, monospaced: true)
                }
            }

            if ticket.kind == .login {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(LiquidPalette.primaryText)
                        .padding(.top, 1)

                    Text("这是登录二维码而非课堂签到码；如需添加账号，请前往「账号」页使用手机号验证码登录或手动导入。")
                        .font(.footnote)
                        .foregroundStyle(LiquidPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    LiquidPalette.subtleSurface(colorScheme),
                    in: RoundedRectangle(cornerRadius: LiquidMetrics.cornerRadiusControl, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: LiquidMetrics.cornerRadiusControl, style: .continuous)
                        .strokeBorder(LiquidPalette.hairline(colorScheme), lineWidth: 0.75)
                        .allowsHitTesting(false)
                }
            }

            if !store.isCurrentTicketHostTrusted() {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(LiquidPalette.primaryText)
                        .padding(.top, 1)

                    Text("目标域名不在受信任白名单内，已暂停自动签到，请核对二维码来源后再手动执行。")
                        .font(.footnote)
                        .foregroundStyle(LiquidPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    LiquidPalette.subtleSurface(colorScheme),
                    in: RoundedRectangle(cornerRadius: LiquidMetrics.cornerRadiusControl, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: LiquidMetrics.cornerRadiusControl, style: .continuous)
                        .strokeBorder(LiquidPalette.hairline(colorScheme), lineWidth: 0.75)
                        .allowsHitTesting(false)
                }
            }

            if shouldShowResultSummary(for: ticket) {
                latestResultSummaryStrip
            }
        }
        .padding(LiquidMetrics.cardPadding)
        .liquidGlassCard()
    }

    private var latestResultSummaryStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            latestResultSummaryHeader

            VStack(alignment: .leading, spacing: 8) {
                ForEach(orderedLatestResults) { result in
                    latestResultRow(result)
                }
            }
        }
    }

    private var latestResultSummaryHeader: some View {
        Group {
            if latestIsDryRunBatch {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "testtube.2")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LiquidPalette.accent)

                    Text("演练完成 · 已模拟 \(store.results.count) 个账号")
                        .font(.footnote.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(LiquidPalette.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    Spacer(minLength: 8)

                    copyBatchDiagnosticsButton
                }
            } else if latestFailedCount > 0 {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.orange)

                        Text("成功 \(latestSucceededCount) · 失败 \(latestFailedCount)")
                            .font(.footnote.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(LiquidPalette.primaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.88)

                        Spacer(minLength: 8)

                        Text("共 \(store.results.count) 个账号")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(LiquidPalette.tertiaryText)
                            .lineLimit(1)
                    }

                    HStack(spacing: 8) {
                        Button {
                            store.retryFailed()
                        } label: {
                            Label("重试失败项", systemImage: "arrow.clockwise")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(LiquidPalette.accent)
                                .lineLimit(1)
                                .minimumScaleFactor(0.86)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .frame(maxWidth: .infinity, minHeight: 34)
                                .background(
                                    LiquidPalette.accent.opacity(colorScheme == .dark ? 0.16 : 0.10),
                                    in: Capsule()
                                )
                                .overlay {
                                    Capsule()
                                        .strokeBorder(
                                            LiquidPalette.accent.opacity(colorScheme == .dark ? 0.28 : 0.20),
                                            lineWidth: 0.75
                                        )
                                        .allowsHitTesting(false)
                                }
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)

                        copyBatchDiagnosticsButton
                    }
                }
            } else {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LiquidPalette.accent)

                    Text("成功 \(latestSucceededCount) · 失败 \(latestFailedCount)")
                        .font(.footnote.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(LiquidPalette.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.88)

                    Spacer(minLength: 8)

                    copyBatchDiagnosticsButton
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LiquidPalette.subtleSurface(colorScheme),
            in: RoundedRectangle(cornerRadius: LiquidMetrics.cornerRadiusControl, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: LiquidMetrics.cornerRadiusControl, style: .continuous)
                .strokeBorder(
                    latestFailedCount > 0 && !latestIsDryRunBatch
                        ? Color.orange.opacity(colorScheme == .dark ? 0.34 : 0.24)
                        : LiquidPalette.hairline(colorScheme),
                    lineWidth: 0.75
                )
                .allowsHitTesting(false)
        }
    }

    private var copyBatchDiagnosticsButton: some View {
        Button {
            copyBatchDiagnostics()
        } label: {
            Label("复制诊断", systemImage: "doc.on.doc")
                .font(.footnote.weight(.medium))
                .foregroundStyle(LiquidPalette.primaryText)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(minWidth: 88, minHeight: 34)
                .background(LiquidPalette.elevatedSurface(colorScheme), in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(LiquidPalette.hairline(colorScheme), lineWidth: 0.75)
                        .allowsHitTesting(false)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
    }

    private func latestResultRow(_ result: SignResult) -> some View {
        let isExpanded = expandedResultIds.contains(result.id)
        let isFailure = result.state.isFailureLike

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: result.state.symbolName)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(statusForegroundColor(for: result.state))

                        Text(result.accountLabel)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(LiquidPalette.primaryText)
                            .lineLimit(1)
                    }

                    if !result.host.isEmpty {
                        Text("\(LiquidPalette.editionDisplayName(forHost: result.host)) · \(result.host)")
                            .font(.caption2)
                            .foregroundStyle(LiquidPalette.tertiaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 8)

                Text(result.state.displayTitle)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(statusForegroundColor(for: result.state))
                    .lineLimit(1)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(statusPillFill(for: result.state), in: Capsule())
                    .overlay {
                        Capsule()
                            .strokeBorder(statusPillBorder(for: result.state), lineWidth: 0.75)
                            .allowsHitTesting(false)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
            }

            Text(result.diagnosticReason)
                .font(isFailure ? .footnote : .caption)
                .foregroundStyle(isFailure ? LiquidPalette.primaryText : LiquidPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            resultMetaChips(for: result)

            if !result.attempts.isEmpty || isFailure {
                HStack(alignment: .center, spacing: 8) {
                    if !result.attempts.isEmpty {
                        Button {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                                toggleExpandedResult(result.id)
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                    .font(.caption2.weight(.semibold))
                                Text(isExpanded ? "收起请求链路" : "查看请求链路（\(result.attempts.count)）")
                                    .font(.caption.weight(.medium))
                                    .monospacedDigit()
                            }
                            .foregroundStyle(LiquidPalette.accent)
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer(minLength: 8)

                    if isFailure {
                        Button {
                            copySingleDiagnostic(result)
                        } label: {
                            Label("复制", systemImage: "doc.on.doc")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(LiquidPalette.secondaryText)
                                .lineLimit(1)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(LiquidPalette.elevatedSurface(colorScheme), in: Capsule())
                                .overlay {
                                    Capsule()
                                        .strokeBorder(LiquidPalette.hairline(colorScheme), lineWidth: 0.6)
                                        .allowsHitTesting(false)
                                }
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }

            if isExpanded && !result.attempts.isEmpty {
                Divider()
                    .overlay(LiquidPalette.hairline(colorScheme))

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(result.attempts.enumerated()), id: \.offset) { index, attempt in
                        latestAttemptCard(attempt, index: index)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LiquidPalette.subtleSurface(colorScheme),
            in: RoundedRectangle(cornerRadius: LiquidMetrics.cornerRadiusControl, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: LiquidMetrics.cornerRadiusControl, style: .continuous)
                .strokeBorder(
                    isFailure
                        ? Color.orange.opacity(colorScheme == .dark ? 0.34 : 0.24)
                        : LiquidPalette.hairline(colorScheme),
                    lineWidth: 0.75
                )
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func resultMetaChips(for result: SignResult) -> some View {
        let strategy = result.strategyId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasStrategy = !(strategy?.isEmpty ?? true)
        let httpStatus = result.effectiveHttpStatus
        let businessCode = result.effectiveBusinessCode
        let hasPrimaryChips = httpStatus != nil || businessCode != nil || result.elapsedMs > 0

        if hasPrimaryChips || hasStrategy {
            VStack(alignment: .leading, spacing: 4) {
                if hasPrimaryChips {
                    HStack(spacing: 6) {
                        if let httpStatus {
                            diagnosticCodeChip(
                                httpStatus > 0 ? "HTTP \(httpStatus)" : "网络错误",
                                warning: httpStatus < 0 || httpStatus >= 400
                            )
                        }

                        if let businessCode {
                            diagnosticCodeChip(
                                "code \(businessCode)",
                                warning: businessCode != 0
                            )
                        }

                        if result.elapsedMs > 0 {
                            diagnosticCodeChip("\(result.elapsedMs) ms", warning: false)
                        }

                        Spacer(minLength: 0)
                    }
                }

                if let strategy, !strategy.isEmpty {
                    Text("策略：\(strategy)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(LiquidPalette.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private func latestAttemptCard(_ attempt: AttemptTrace, index: Int) -> some View {
        let trimmedMessage = attempt.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUrl = attempt.url.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedFinalUrl = attempt.finalUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSnippet = attempt.rawSnippet?.trimmingCharacters(in: .whitespacesAndNewlines)

        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("#\(index + 1) \(attempt.strategyId) · \(attempt.method)")
                    .font(.system(.caption2, design: .monospaced).weight(.semibold))
                    .foregroundStyle(LiquidPalette.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Spacer(minLength: 4)

                Text("\(attempt.elapsedMs) ms")
                    .font(.system(.caption2, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(LiquidPalette.tertiaryText)
                    .fixedSize(horizontal: true, vertical: false)
            }

            if attempt.httpStatus != nil || attempt.businessCode != nil {
                HStack(spacing: 6) {
                    if let httpStatus = attempt.httpStatus {
                        diagnosticCodeChip(
                            httpStatus > 0 ? "HTTP \(httpStatus)" : "网络错误",
                            warning: httpStatus < 0 || httpStatus >= 400
                        )
                    }
                    if let businessCode = attempt.businessCode {
                        diagnosticCodeChip("code \(businessCode)", warning: businessCode != 0)
                    }
                    Spacer(minLength: 0)
                }
            }

            if !trimmedMessage.isEmpty {
                Text(trimmedMessage)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(LiquidPalette.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            Text(trimmedUrl)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(LiquidPalette.tertiaryText)
                .lineLimit(2)
                .truncationMode(.middle)

            if let trimmedFinalUrl, !trimmedFinalUrl.isEmpty, trimmedFinalUrl != trimmedUrl {
                Text("重定向 → \(trimmedFinalUrl)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(LiquidPalette.secondaryText)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            if let trimmedSnippet, !trimmedSnippet.isEmpty, trimmedSnippet != trimmedMessage {
                VStack(alignment: .leading, spacing: 3) {
                    Text("响应片段")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(LiquidPalette.tertiaryText)

                    Text(trimmedSnippet)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(LiquidPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    LiquidPalette.subtleSurface(colorScheme),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(LiquidPalette.hairline(colorScheme), lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LiquidPalette.elevatedSurface(colorScheme),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(LiquidPalette.hairline(colorScheme), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
    }

    private func diagnosticCodeChip(_ text: String, warning: Bool) -> some View {
        Text(text)
            .font(.system(.caption2, design: .monospaced).weight(.medium))
            .monospacedDigit()
            .foregroundStyle(warning ? Color.orange : LiquidPalette.secondaryText)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                warning
                    ? Color.orange.opacity(colorScheme == .dark ? 0.16 : 0.10)
                    : LiquidPalette.elevatedSurface(colorScheme),
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .strokeBorder(
                        warning
                            ? Color.orange.opacity(colorScheme == .dark ? 0.34 : 0.24)
                            : LiquidPalette.hairline(colorScheme),
                        lineWidth: 0.6
                    )
                    .allowsHitTesting(false)
            }
            .fixedSize(horizontal: true, vertical: false)
    }

    private func statusForegroundColor(for state: SignState) -> Color {
        if state.isSuccessLike {
            return LiquidPalette.accent
        }
        if state.isFailureLike {
            return Color.orange
        }
        return LiquidPalette.secondaryText
    }

    private func statusPillFill(for state: SignState) -> Color {
        if state.isSuccessLike {
            return LiquidPalette.accent.opacity(colorScheme == .dark ? 0.16 : 0.10)
        }
        if state.isFailureLike {
            return Color.orange.opacity(colorScheme == .dark ? 0.16 : 0.10)
        }
        return LiquidPalette.elevatedSurface(colorScheme)
    }

    private func statusPillBorder(for state: SignState) -> Color {
        if state.isSuccessLike {
            return LiquidPalette.accent.opacity(colorScheme == .dark ? 0.30 : 0.22)
        }
        if state.isFailureLike {
            return Color.orange.opacity(colorScheme == .dark ? 0.34 : 0.24)
        }
        return LiquidPalette.hairline(colorScheme)
    }

    private func toggleExpandedResult(_ id: String) {
        if expandedResultIds.contains(id) {
            expandedResultIds.remove(id)
        } else {
            expandedResultIds.insert(id)
        }
    }

    private func copyBatchDiagnostics() {
        let failed = latestFailedResults
        let targets = failed.isEmpty ? orderedLatestResults : failed
        guard !targets.isEmpty else { return }
        let report = targets
            .map(\.diagnosticReportText)
            .joined(separator: "\n\n---\n\n")
        #if canImport(UIKit)
        UIPasteboard.general.string = report
        #endif
        store.showToast("已复制失败原因与诊断信息")
    }

    private func copySingleDiagnostic(_ result: SignResult) {
        #if canImport(UIKit)
        UIPasteboard.general.string = result.diagnosticReportText
        #endif
        store.showToast("已复制失败原因与诊断信息")
    }

    private func ticketMetaRow(label: String, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(LiquidPalette.tertiaryText)
                .frame(width: 52, alignment: .leading)

            Text(value)
                .font(monospaced ? .system(.subheadline, design: .monospaced) : .subheadline)
                .foregroundStyle(LiquidPalette.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func dynamicCountdownView(issuedAt: TimeInterval) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = max(0, Int(context.date.timeIntervalSince1970 - issuedAt))
            let isWarning = elapsed >= 8
            let elapsedLabel = elapsed < 600 ? "\(elapsed)s" : "\(elapsed / 60) 分钟"
            let labelText = "动态码已过去 \(elapsedLabel)（通常 8–15 秒刷新）"

            HStack(spacing: 8) {
                Image(systemName: isWarning ? "clock.badge.exclamationmark" : "clock")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isWarning ? Color.orange : LiquidPalette.secondaryText)

                Text(labelText)
                    .font(.caption.weight(isWarning ? .semibold : .medium))
                    .monospacedDigit()
                    .foregroundStyle(isWarning ? Color.orange : LiquidPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isWarning
                    ? Color.orange.opacity(colorScheme == .dark ? 0.16 : 0.10)
                    : LiquidPalette.subtleSurface(colorScheme),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isWarning
                            ? Color.orange.opacity(colorScheme == .dark ? 0.34 : 0.24)
                            : LiquidPalette.hairline(colorScheme),
                        lineWidth: 0.75
                    )
                    .allowsHitTesting(false)
            }
        }
    }

    private var dynamicFreshnessHintView: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.caption.weight(.semibold))
                .foregroundStyle(LiquidPalette.secondaryText)

            Text("动态签到码通常 8–15 秒刷新，请尽快完成签到")
                .font(.caption.weight(.medium))
                .foregroundStyle(LiquidPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LiquidPalette.subtleSurface(colorScheme),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(LiquidPalette.hairline(colorScheme), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
    }

    private var accountSelectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                LiquidSectionHeader(
                    title: "1. 选择签到账号",
                    trailing: "已选 \(selectedEnabledCount) / \(enabledAccounts.count)"
                )

                if !enabledAccounts.isEmpty {
                    Button {
                        store.toggleSelectAllEnabled()
                    } label: {
                        Text(allEnabledSelected ? "取消全选" : "全选")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(LiquidPalette.accent)
                            .lineLimit(1)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .frame(minWidth: 72, minHeight: 30)
                            .background(
                                LiquidPalette.accent.opacity(colorScheme == .dark ? 0.16 : 0.10),
                                in: Capsule()
                            )
                            .overlay {
                                Capsule()
                                    .strokeBorder(
                                        LiquidPalette.accent.opacity(colorScheme == .dark ? 0.28 : 0.20),
                                        lineWidth: 0.75
                                    )
                                    .allowsHitTesting(false)
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isCheckingIn)
                    .opacity(store.isCheckingIn ? 0.5 : 1.0)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
                }
            }

            if enabledAccounts.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .font(.title3)
                        .foregroundStyle(LiquidPalette.secondaryText)

                    VStack(spacing: 4) {
                        Text("暂无已启用账号")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(LiquidPalette.primaryText)
                        Text("请前往「账号」页面添加或启用账号。")
                            .font(.footnote)
                            .foregroundStyle(LiquidPalette.secondaryText)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 26)
                .padding(.horizontal, LiquidMetrics.cardPadding)
                .background(
                    LiquidPalette.elevatedSurface(colorScheme),
                    in: RoundedRectangle(cornerRadius: LiquidMetrics.cornerRadiusCard, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: LiquidMetrics.cornerRadiusCard, style: .continuous)
                        .strokeBorder(LiquidPalette.hairline(colorScheme), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(enabledAccounts.enumerated()), id: \.element.id) { index, account in
                        let isSelected = store.selectedAccountIds.contains(account.id)
                        Button {
                            store.toggleSelection(accountId: account.id)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(isSelected ? LiquidPalette.accent : LiquidPalette.secondaryText)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(account.label)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(LiquidPalette.primaryText)
                                        .lineLimit(1)

                                    Text("\(LiquidPalette.editionDisplayName(forHost: account.host)) · \(account.authKindLabel)")
                                        .font(.caption)
                                        .foregroundStyle(LiquidPalette.secondaryText)
                                        .lineLimit(1)
                                }

                                Spacer(minLength: 8)

                                if !account.hasCredential {
                                    Text("缺少凭据")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(LiquidPalette.secondaryText)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(LiquidPalette.subtleSurface(colorScheme), in: Capsule())
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .background(
                                isSelected
                                    ? LiquidPalette.accent.opacity(colorScheme == .dark ? 0.08 : 0.045)
                                    : Color.clear
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(store.isCheckingIn)
                        .opacity(store.isCheckingIn ? 0.65 : 1.0)

                        if index < enabledAccounts.count - 1 {
                            Divider()
                                .overlay(LiquidPalette.hairline(colorScheme))
                                .padding(.leading, 48)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: LiquidMetrics.cornerRadiusCard, style: .continuous))
                .background(
                    LiquidPalette.elevatedSurface(colorScheme),
                    in: RoundedRectangle(cornerRadius: LiquidMetrics.cornerRadiusCard, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: LiquidMetrics.cornerRadiusCard, style: .continuous)
                        .strokeBorder(LiquidPalette.hairline(colorScheme), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private var checkInProgressCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ProgressView()
                    .tint(LiquidPalette.accent)

                VStack(alignment: .leading, spacing: 2) {
                    Text(store.dryRun ? "正在执行模拟演练" : "正在自动签到")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LiquidPalette.primaryText)

                    Text("进度 \(store.checkInCompletedCount) / \(max(store.checkInTotalCount, 1))")
                        .font(.system(.caption, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(LiquidPalette.secondaryText)
                }

                Spacer(minLength: 8)

                Button("取消") {
                    store.cancelCheckIn()
                }
                .liquidSecondaryButtonStyle(
                    minWidth: 96,
                    horizontalPadding: LiquidMetrics.buttonCompactHorizontalPadding
                )
            }

            ProgressView(
                value: Double(max(0, min(store.checkInCompletedCount, max(store.checkInTotalCount, 1)))),
                total: Double(max(store.checkInTotalCount, 1))
            )
            .tint(LiquidPalette.accent)
        }
        .padding(LiquidMetrics.cardPadding)
        .liquidGlassCard()
    }

    private var manualRerunButton: some View {
        Button {
            store.startCheckIn()
        } label: {
            Label(
                store.dryRun ? "重新执行演练" : "重新为已选账号签到",
                systemImage: store.dryRun ? "testtube.2" : "arrow.clockwise"
            )
        }
        .liquidSecondaryButtonStyle(
            minWidth: nil,
            horizontalPadding: LiquidMetrics.buttonHorizontalPadding,
            fullWidth: true
        )
    }

    private func handlePasteAction() {
        #if canImport(UIKit)
        let clipboard = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !clipboard.isEmpty {
            store.applyQrInput(clipboard, autoStartCheckIn: true)
            return
        }
        #endif
        manualInputText = ""
        showManualInput = true
    }

    private func ticketSymbol(for kind: TicketKind) -> String {
        switch kind {
        case .dynamicCheckin: return "qrcode"
        case .lessonOnly: return "book.closed"
        case .login: return "person.badge.key"
        case .unknown: return "link"
        }
    }
}

private struct ManualLinkInputSheet: View {
    @Binding var text: String
    let selectedAccountCount: Int
    let isDryRun: Bool
    let onConfirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var descriptionText: String {
        if selectedAccountCount > 0 {
            return isDryRun
                ? "输入或粘贴雨课堂签到链接，确认后将为已选的 \(selectedAccountCount) 个账号自动执行演练。"
                : "输入或粘贴雨课堂签到链接，确认后将为已选的 \(selectedAccountCount) 个账号自动签到。"
        }
        return "输入或粘贴雨课堂签到链接。当前尚未选择账号，识别后请先在签到页勾选要签到的账号。"
    }

    private var confirmButtonTitle: String {
        guard selectedAccountCount > 0 else { return "识别链接" }
        return isDryRun ? "识别并自动演练" : "识别并自动签到"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidCanvas()

                VStack(alignment: .leading, spacing: 18) {
                    Text(descriptionText)
                        .font(.subheadline)
                        .foregroundStyle(LiquidPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    TextField("粘贴或输入二维码内容", text: $text, axis: .vertical)
                        .lineLimit(3...6)
                        .font(.system(.subheadline, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(14)
                        .background(
                            LiquidPalette.elevatedSurface(colorScheme),
                            in: RoundedRectangle(cornerRadius: LiquidMetrics.cornerRadiusControl, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: LiquidMetrics.cornerRadiusControl, style: .continuous)
                                .strokeBorder(LiquidPalette.hairline(colorScheme), lineWidth: 1)
                                .allowsHitTesting(false)
                        }

                    LiquidGlassGroup(spacing: 12) {
                        VStack(spacing: 12) {
                            Button {
                                onConfirm(trimmed)
                                dismiss()
                            } label: {
                                Label(confirmButtonTitle, systemImage: "qrcode.viewfinder")
                            }
                            .liquidPrimaryButtonStyle(
                                minWidth: nil,
                                horizontalPadding: LiquidMetrics.buttonHorizontalPadding,
                                fullWidth: true
                            )
                            .disabled(trimmed.isEmpty)

                            #if canImport(UIKit)
                            Button {
                                if let pasted = UIPasteboard.general.string {
                                    text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                                }
                            } label: {
                                Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
                            }
                            .liquidSecondaryButtonStyle(
                                minWidth: nil,
                                horizontalPadding: LiquidMetrics.buttonHorizontalPadding,
                                fullWidth: true
                            )
                            #endif
                        }
                    }

                    Spacer()
                }
                .padding(.horizontal, LiquidMetrics.pageHorizontalPadding)
                .padding(.top, 16)
                .padding(.bottom, LiquidMetrics.scrollBottomPadding)
            }
            .navigationTitle("输入链接")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确认") {
                        onConfirm(trimmed)
                        dismiss()
                    }
                    .disabled(trimmed.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
