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

                if ticket.kind == .dynamicCheckin, let issuedAt = ticket.issuedAtEpochSeconds {
                    dynamicCountdownView(issuedAt: issuedAt)
                }

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
        HStack(alignment: .center, spacing: 10) {
            if latestIsDryRunBatch {
                Image(systemName: "testtube.2")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LiquidPalette.accent)

                Text("演练完成 · 已模拟 \(store.results.count) 个账号")
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(LiquidPalette.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.88)

                Spacer(minLength: 0)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: latestFailedCount == 0 ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(latestFailedCount == 0 ? LiquidPalette.accent : LiquidPalette.primaryText)

                    Text("成功 \(latestSucceededCount) · 失败 \(latestFailedCount)")
                        .font(.footnote.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(LiquidPalette.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.88)
                }

                Spacer(minLength: 8)

                if latestFailedCount > 0 {
                    Button {
                        store.retryFailed()
                    } label: {
                        Text("重试失败项")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(LiquidPalette.accent)
                            .lineLimit(1)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .frame(minWidth: 88, minHeight: 32)
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
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
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
                .strokeBorder(LiquidPalette.hairline(colorScheme), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
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
            let defaultWindow = 30
            let remaining = max(0, defaultWindow - elapsed)
            let labelText = remaining > 0 ? "约剩 \(remaining)s" : "已生成 \(elapsed)s"

            Text(labelText)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(remaining > 0 ? LiquidPalette.primaryText : LiquidPalette.secondaryText)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(LiquidPalette.subtleSurface(colorScheme), in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(LiquidPalette.hairline(colorScheme), lineWidth: 0.75)
                        .allowsHitTesting(false)
                }
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
