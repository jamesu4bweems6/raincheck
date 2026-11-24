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
        enabledAccounts.filter { store.selectedAccountIds.contains($0.id) }.count
    }

    private var allEnabledSelected: Bool {
        !enabledAccounts.isEmpty && selectedEnabledCount == enabledAccounts.count
    }

    private var canStartCheckIn: Bool {
        guard let ticket = store.currentTicket, ticket.kind != .login else { return false }
        return selectedEnabledCount > 0 && !store.isCheckingIn
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

                        scanHeroCard

                        if let ticket = store.currentTicket {
                            ticketSummaryCard(ticket)
                        }

                        accountSelectionSection

                        actionFooter
                    }
                    .padding(.horizontal, LiquidMetrics.pageHorizontalPadding)
                    .padding(.vertical, 16)
                }
            }
            .navigationTitle("签到")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Toggle(isOn: $store.dryRun) {
                            Label("演练模式", systemImage: "testtube.2")
                        }

                        Button {
                            manualInputText = ""
                            showManualInput = true
                        } label: {
                            Label("手动输入链接", systemImage: "keyboard")
                        }

                        if store.currentTicket != nil {
                            Button {
                                store.clearTicket()
                            } label: {
                                Label("清除当前二维码", systemImage: "xmark.circle")
                            }
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
                    onScanned: { raw in
                        store.applyQrInput(raw)
                    },
                    onManualPaste: {
                        pendingManualPasteAfterScanner = true
                    }
                )
            }
            .sheet(isPresented: $showManualInput) {
                ManualLinkInputSheet(
                    text: $manualInputText,
                    onConfirm: { raw in
                        store.applyQrInput(raw)
                    }
                )
            }
        }
    }

    private var dryRunBanner: some View {
        HStack(spacing: 10) {
            LiquidStatusChip(symbol: "testtube.2", text: "演练模式 · 不发送网络请求", emphasized: true)
            Spacer(minLength: 8)
            Button("关闭") {
                store.dryRun = false
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(LiquidPalette.secondaryText)
        }
    }

    private var scanHeroCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("扫描课堂二维码")
                    .font(.headline)
                    .foregroundStyle(LiquidPalette.primaryText)

                Text("支持动态签到码与课堂链接，识别后由你确认再执行。")
                    .font(.subheadline)
                    .foregroundStyle(LiquidPalette.secondaryText)
            }

            LiquidGlassGroup(spacing: 12) {
                HStack(spacing: 12) {
                    Button {
                        showScanner = true
                    } label: {
                        Label("扫描二维码", systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .liquidPrimaryButtonStyle()

                    Button {
                        handlePasteAction()
                    } label: {
                        Label("粘贴链接", systemImage: "doc.on.clipboard")
                            .frame(maxWidth: .infinity)
                    }
                    .liquidSecondaryButtonStyle()
                }
            }
        }
        .padding(LiquidMetrics.cardPadding)
        .liquidGlassCard()
    }

    private func ticketSummaryCard(_ ticket: QrTicket) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
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
                        .frame(width: 28, height: 28)
                        .background(LiquidPalette.subtleSurface(colorScheme), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除当前二维码")
            }

            VStack(alignment: .leading, spacing: 6) {
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
            }

            if !store.isCurrentTicketHostTrusted() {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(LiquidPalette.primaryText)
                        .padding(.top, 1)

                    Text("目标域名不在受信任白名单内，请核对二维码来源后再确认签到。")
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
            }
        }
        .padding(LiquidMetrics.cardPadding)
        .liquidGlassCard()
    }

    private func ticketMetaRow(label: String, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(LiquidPalette.tertiaryText)
                .frame(width: 48, alignment: .leading)

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
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .monospacedDigit()
                .foregroundStyle(remaining > 0 ? LiquidPalette.primaryText : LiquidPalette.secondaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(LiquidPalette.subtleSurface(colorScheme), in: Capsule())
        }
    }

    private var accountSelectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                LiquidSectionHeader(
                    title: "参与账号",
                    trailing: "已选 \(selectedEnabledCount) / \(enabledAccounts.count)"
                )

                if !enabledAccounts.isEmpty {
                    Button(allEnabledSelected ? "取消全选" : "全选") {
                        store.toggleSelectAllEnabled()
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(LiquidPalette.accent)
                }
            }

            if enabledAccounts.isEmpty {
                VStack(spacing: 6) {
                    Text("暂无已启用账号")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(LiquidPalette.primaryText)
                    Text("请前往「账号」页面添加或启用账号。")
                        .font(.footnote)
                        .foregroundStyle(LiquidPalette.secondaryText)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .padding(.horizontal, LiquidMetrics.cardPadding)
                .background(
                    LiquidPalette.elevatedSurface(colorScheme),
                    in: RoundedRectangle(cornerRadius: LiquidMetrics.cornerRadiusCard, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: LiquidMetrics.cornerRadiusCard, style: .continuous)
                        .strokeBorder(LiquidPalette.hairline(colorScheme), lineWidth: 1)
                )
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

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(account.label)
                                        .font(.subheadline.weight(.medium))
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
                                        .font(.caption2)
                                        .foregroundStyle(LiquidPalette.tertiaryText)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 13)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if index < enabledAccounts.count - 1 {
                            Divider()
                                .overlay(LiquidPalette.hairline(colorScheme))
                                .padding(.leading, 48)
                        }
                    }
                }
                .background(
                    LiquidPalette.elevatedSurface(colorScheme),
                    in: RoundedRectangle(cornerRadius: LiquidMetrics.cornerRadiusCard, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: LiquidMetrics.cornerRadiusCard, style: .continuous)
                        .strokeBorder(LiquidPalette.hairline(colorScheme), lineWidth: 1)
                )
            }
        }
    }

    @ViewBuilder
    private var actionFooter: some View {
        if store.isCheckingIn {
            HStack(spacing: 14) {
                ProgressView()
                    .tint(LiquidPalette.accent)

                VStack(alignment: .leading, spacing: 2) {
                    Text(store.dryRun ? "正在执行模拟演练" : "正在签到")
                        .font(.subheadline.weight(.medium))
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
                .liquidSecondaryButtonStyle()
            }
            .padding(LiquidMetrics.cardPadding)
            .liquidGlassCard()
        } else {
            Button {
                store.startCheckIn()
            } label: {
                Text(store.dryRun ? "模拟演练" : "开始签到")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .liquidPrimaryButtonStyle()
            .disabled(!canStartCheckIn)
        }
    }

    private func handlePasteAction() {
        #if canImport(UIKit)
        let clipboard = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !clipboard.isEmpty {
            store.applyQrInput(clipboard)
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
    let onConfirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidCanvas()

                VStack(alignment: .leading, spacing: 16) {
                    Text("剪贴板为空时，可在此直接输入或粘贴雨课堂签到链接。")
                        .font(.subheadline)
                        .foregroundStyle(LiquidPalette.secondaryText)

                    TextField("粘贴或输入二维码内容", text: $text, axis: .vertical)
                        .lineLimit(3...6)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(14)
                        .background(
                            LiquidPalette.elevatedSurface(colorScheme),
                            in: RoundedRectangle(cornerRadius: LiquidMetrics.cornerRadiusControl, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: LiquidMetrics.cornerRadiusControl, style: .continuous)
                                .strokeBorder(LiquidPalette.hairline(colorScheme), lineWidth: 1)
                        )

                    Spacer()
                }
                .padding(.horizontal, LiquidMetrics.pageHorizontalPadding)
                .padding(.top, 16)
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
                    Button("识别") {
                        onConfirm(trimmed)
                        dismiss()
                    }
                    .disabled(trimmed.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
