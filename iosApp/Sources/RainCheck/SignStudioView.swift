//
//  SignStudioView.swift
//  RainCheck
//
//  液态玻璃「签到台」：
//   - 顶部液态玻璃二维码状态主卡（动态码实时倒计时与 c/t/s/v 参数胶囊、静态课堂徽章、
//     登录码拦截引导、恶意外部域名安全警告）；
//   - 液态玻璃交互操作条（一键扫码 / 剪贴板粘贴 / 演练模式切换 / 高级参数浮层）；
//   - 清晰账号勾选玻璃胶囊流（彻底消灭旧版「全不选 = 全选」反直觉逻辑，带全选 / 反选 / 参与人数徽章）；
//   - 高亮 `.glassProminent` 一键并发签到与实时玻璃进度环；
//   - 默认关闭 `autoSignOnScan`（false），杜绝扫到恶意码零点击外泄凭据。
//

import SwiftUI
import UIKit

struct SignStudioView: View {
    @EnvironmentObject private var app: AppState
    @Namespace private var studioNamespace

    @State private var showingScanner = false
    @State private var showingOptionsSheet = false
    @State private var showingManualInput = false
    @State private var manualText = ""
    /// 安全默认：严格关闭扫码后自动发包，避免镜头扫到外部恶意码零点击外泄凭据。
    @State private var autoSignOnScan = false

    init() {}

    private var currentWarning: String? {
        guard let ticket = app.ticket else { return nil }
        return app.qrSecurityWarning(for: ticket)
    }

    private var canvasAccent: Color {
        if currentWarning != nil { return LiquidPalette.coral }
        if app.options.dryRun { return LiquidPalette.violet }
        guard let ticket = app.ticket else { return LiquidPalette.sapphire }
        switch ticket.kind {
        case .DYNAMIC_CHECKIN: return LiquidPalette.cyan
        case .LESSON_ONLY: return LiquidPalette.emerald
        case .LOGIN: return LiquidPalette.amber
        case .UNKNOWN: return LiquidPalette.slate
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidAuroraCanvas(accent: canvasAccent)

                ScrollView {
                    VStack(spacing: 18) {
                        heroTicketCard
                        actionControlDeck

                        if showingManualInput {
                            manualInputCard
                                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                        }

                        if let ticket = app.ticket, ticket.kind != .LOGIN {
                            strategyPreviewCard(ticket)
                        }

                        accountSelectionSection
                        launchConsoleCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("签到台")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingOptionsSheet = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel("高级签到参数")
                }
            }
            .fullScreenCover(isPresented: $showingScanner) {
                LiquidScannerSheet { code in
                    handleScannedText(code, fromCamera: true)
                }
            }
            .sheet(isPresented: $showingOptionsSheet) {
                SignOptionsSheet(autoSignOnScan: $autoSignOnScan)
                    .environmentObject(app)
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.84), value: app.ticket?.raw)
        .animation(.spring(response: 0.30, dampingFraction: 0.86), value: showingManualInput)
    }

    // MARK: 顶部液态玻璃二维码状态主卡

    @ViewBuilder
    private var heroTicketCard: some View {
        if let ticket = app.ticket {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: ticket.kind.symbolName)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(heroTint(for: ticket))
                        .frame(width: 46, height: 46)
                        .liquidGlass(.clear, tint: heroTint(for: ticket), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(ticket.kind.displayName)
                                .font(.headline.weight(.bold))
                            if let host = ticket.host {
                                LiquidStatusPill(
                                    text: LiquidPalette.editionBadgeName(forHost: host),
                                    tint: LiquidPalette.accent(forHost: host)
                                )
                            }
                        }
                        Text(ticket.summary())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 4)

                    Button {
                        LiquidHaptics.impact(.light)
                        manualText = ""
                        app.clearTicket()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("清空当前二维码")
                }

                // 动态码实时倒计时 / 参数胶囊
                if ticket.kind == .DYNAMIC_CHECKIN {
                    dynamicTelemetryRow(ticket)
                }

                // 静态课堂徽章与上下文参数
                contextPillsRow(ticket)

                // 登录码拦截提示
                if ticket.kind == .LOGIN {
                    loginInterceptionBanner
                }

                // 恶意外部域名 / 非白名单明文 HTTP 警告
                if let warning = currentWarning {
                    securityWarningBanner(warning, host: ticket.host)
                }

                // 原始负载只读预览
                Text(ticket.raw)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .liquidReadableSurface(cornerRadius: 12)
            }
            .padding(18)
            .liquidGlassCard(cornerRadius: 26, variant: .regular, tint: heroTint(for: ticket))
            .liquidGlassMorphID("hero-card", in: studioNamespace)
        } else {
            emptyHeroCard
        }
    }

    private var emptyHeroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(LiquidPalette.sapphire)
                    .frame(width: 48, height: 48)
                    .liquidGlass(.clear, tint: LiquidPalette.sapphire, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text("准备就绪 · 等待课堂二维码")
                        .font(.headline.weight(.bold))
                    Text("支持动态码（c/t/s/v）、静态课堂链接、纯课堂号与本地演练码")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                LiquidStatusPill(
                    text: "默认安全确认",
                    symbol: "checkmark.shield.fill",
                    tint: LiquidPalette.emerald
                )
                LiquidStatusPill(
                    text: "白名单域校验",
                    symbol: "lock.fill",
                    tint: LiquidPalette.sapphire
                )
                if app.options.dryRun {
                    LiquidStatusPill(
                        text: "演练模式",
                        symbol: "waveform.path.ecg",
                        tint: LiquidPalette.violet
                    )
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassCard(cornerRadius: 26, variant: .regular, tint: LiquidPalette.sapphire)
        .liquidGlassMorphID("hero-card", in: studioNamespace)
    }

    private func dynamicTelemetryRow(_ ticket: QrTicket) -> some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
            let ageInfo = dynamicAgeDescription(for: ticket, now: context.date)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    LiquidStatusPill(
                        text: ageInfo.label,
                        symbol: "timer",
                        tint: ageInfo.tint
                    )
                    if let v = ticket.version {
                        LiquidStatusPill(text: "v=\(v)", tint: LiquidPalette.sapphire)
                    }
                    Spacer()
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if let c = ticket.dynamicCode {
                            paramChip("c", String(c.prefix(12)))
                        }
                        if let t = ticket.timestamp {
                            paramChip("t", t)
                        }
                        if let s = ticket.signature {
                            paramChip("s", String(s.prefix(12)))
                        }
                    }
                }
            }
        }
    }

    private func dynamicAgeDescription(for ticket: QrTicket, now: Date) -> (label: String, tint: Color) {
        guard let date = ticket.parsedTimestampDate else {
            return ("动态码已载入", LiquidPalette.cyan)
        }
        let elapsed = Int(now.timeIntervalSince(date))
        if elapsed < -60 {
            return ("预置时间戳 t", LiquidPalette.cyan)
        }
        if elapsed <= 8 {
            return ("新鲜 · \(max(0, elapsed))s 前", LiquidPalette.emerald)
        }
        if elapsed <= 30 {
            return ("动态码已过 \(elapsed)s", LiquidPalette.amber)
        }
        return ("可能已轮换（\(elapsed)s 前）", LiquidPalette.rose)
    }

    private func contextPillsRow(_ ticket: QrTicket) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let lessonId = ticket.lessonId {
                    LiquidStatusPill(text: "课堂 \(lessonId)", symbol: "book.closed", tint: LiquidPalette.emerald)
                } else if ticket.kind != .LOGIN {
                    LiquidStatusPill(text: "运行时自动探测 lessonId", symbol: "sparkle.magnifyingglass", tint: LiquidPalette.amber)
                }
                if let classroomId = ticket.classroomId {
                    LiquidStatusPill(text: "班级 \(classroomId)", symbol: "building.2", tint: LiquidPalette.cyan)
                }
                if let checkinId = ticket.checkinId {
                    LiquidStatusPill(text: "签到 \(checkinId)", symbol: "number", tint: LiquidPalette.violet)
                }
            }
        }
    }

    private var loginInterceptionBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.raised.fill")
                .font(.headline)
                .foregroundStyle(LiquidPalette.amber)
            VStack(alignment: .leading, spacing: 2) {
                Text("已拦截登录二维码")
                    .font(.subheadline.weight(.semibold))
                Text("签到台不会把账号凭据发往登录码；请前往「账号舱」扫码登录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            LiquidGlassActionButton(prominence: .glass, tint: LiquidPalette.amber) {
                app.activeTab = .vault
            } label: {
                Text("去账号舱")
                    .font(.caption.weight(.semibold))
            }
        }
        .padding(12)
        .liquidReadableSurface(cornerRadius: 16)
    }

    private func securityWarningBanner(_ reason: String, host: String?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "shield.slash.fill")
                .font(.headline)
                .foregroundStyle(LiquidPalette.coral)
            VStack(alignment: .leading, spacing: 3) {
                Text("外部域名安全警告")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(LiquidPalette.coral)
                Text("检测到非白名单目标\(host.map { "（\($0)）" } ?? "")：\(reason)。引擎已自动阻断 QR_URL_POST / QR_URL_GET，绝不外泄账号凭据。")
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LiquidPalette.coral.opacity(0.14))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(LiquidPalette.coral.opacity(0.45), lineWidth: 1)
        }
    }

    private func paramChip(_ key: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(.caption2, design: .monospaced).weight(.bold))
                .foregroundStyle(LiquidPalette.cyan)
            Text(value)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .liquidReadableSurface(cornerRadius: 10)
    }

    // MARK: 液态玻璃交互操作条

    private var actionControlDeck: some View {
        LiquidGlassGroup(spacing: 10) {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    LiquidGlassActionButton(prominence: .prominent, tint: LiquidPalette.sapphire) {
                        LiquidHaptics.impact(.medium)
                        showingScanner = true
                    } label: {
                        Label("相机扫码", systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity)
                    }

                    LiquidGlassActionButton(prominence: .glass, tint: LiquidPalette.cyan) {
                        LiquidHaptics.impact(.light)
                        pasteFromClipboard()
                    } label: {
                        Label("粘贴剪贴板", systemImage: "doc.on.clipboard")
                            .frame(maxWidth: .infinity)
                    }
                }

                HStack(spacing: 10) {
                    LiquidGlassActionButton(
                        prominence: app.options.dryRun ? .prominent : .glass,
                        tint: LiquidPalette.violet
                    ) {
                        LiquidHaptics.impact(.light)
                        app.options.dryRun.toggle()
                    } label: {
                        Label(
                            app.options.dryRun ? "演练已开（零发包）" : "演练模式",
                            systemImage: "waveform.path.ecg"
                        )
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                    }

                    LiquidGlassActionButton(prominence: .glass, tint: LiquidPalette.slate) {
                        showingManualInput.toggle()
                        if showingManualInput && manualText.isEmpty {
                            manualText = app.scannedText
                        }
                    } label: {
                        Label(
                            showingManualInput ? "收起输入" : "手动输入",
                            systemImage: "keyboard"
                        )
                        .font(.caption.weight(.semibold))
                    }

                    LiquidGlassActionButton(prominence: .glass, tint: LiquidPalette.sapphire) {
                        showingOptionsSheet = true
                    } label: {
                        Label("\(app.options.concurrency)并发", systemImage: "speedometer")
                            .font(.caption.weight(.semibold))
                    }
                }
            }
        }
    }

    private var manualInputCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("手动粘贴二维码 URL、裸参数或纯课堂号")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField("例如：https://www.yuketang.cn/... 或 1529274209982060032", text: $manualText, axis: .vertical)
                .lineLimit(2...4)
                .font(.system(.footnote, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .padding(12)
                .liquidReadableSurface(cornerRadius: 14)

            HStack {
                LiquidGlassActionButton(prominence: .prominent, tint: LiquidPalette.cyan) {
                    handleScannedText(manualText, fromCamera: false)
                    showingManualInput = false
                } label: {
                    Label("解析二维码", systemImage: "sparkles")
                        .font(.caption.weight(.semibold))
                }
                .disabled(manualText.trimmed.isEmpty)

                Spacer()

                if !manualText.isEmpty {
                    Button("清空") {
                        manualText = ""
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .liquidGlassCard(cornerRadius: 22, variant: .regular)
    }

    // MARK: 策略预览

    private func strategyPreviewCard(_ ticket: QrTicket) -> some View {
        let candidates = app.engine.strategiesFor(ticket)
        return VStack(alignment: .leading, spacing: 10) {
            LiquidSectionHeader(
                title: "策略回退链",
                subtitle: "按 protocol_profile.json 顺序命中即停",
                trailingBadge: "\(candidates.count) 条",
                tint: LiquidPalette.cyan
            )

            if candidates.isEmpty {
                Text("当前二维码未匹配到任何可执行策略，请检查二维码格式。")
                    .font(.caption)
                    .foregroundStyle(LiquidPalette.amber)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(candidates.enumerated()), id: \.element.id) { idx, spec in
                            HStack(spacing: 5) {
                                Text("\(idx + 1)")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 18, height: 18)
                                    .background(Circle().fill(LiquidPalette.sapphire))
                                Text(spec.id)
                                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .liquidReadableSurface(cornerRadius: 12)
                        }
                    }
                }
            }
        }
        .padding(16)
        .liquidReadableSurface(cornerRadius: 22)
    }

    // MARK: 账号选择玻璃胶囊流

    private var accountSelectionSection: some View {
        let enabled = app.enabledAccounts
        let selected = app.signTargets()

        return VStack(alignment: .leading, spacing: 12) {
            LiquidSectionHeader(
                title: "参与账号",
                subtitle: enabled.isEmpty
                    ? "请先前往账号舱添加并启用账号"
                    : "明确勾选参与本次并发签到的账号（取消勾选即不参与）",
                trailingBadge: "已选 \(selected.count) / \(enabled.count)",
                tint: selected.isEmpty ? LiquidPalette.amber : LiquidPalette.emerald
            )

            if enabled.isEmpty {
                HStack {
                    Text("当前没有已启用的账号。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    LiquidGlassActionButton(prominence: .glass, tint: LiquidPalette.sapphire) {
                        app.activeTab = .vault
                    } label: {
                        Label("去添加账号", systemImage: "plus")
                            .font(.caption.weight(.semibold))
                    }
                }
                .padding(14)
                .liquidReadableSurface(cornerRadius: 18)
            } else {
                LiquidGlassGroup(spacing: 8) {
                    HStack(spacing: 8) {
                        selectionToolPill("全选", symbol: "checkmark.circle") {
                            app.selectAllEnabled()
                        }
                        selectionToolPill("反选", symbol: "arrow.triangle.2.circlepath") {
                            app.invertSelection()
                        }
                        selectionToolPill("清空", symbol: "circle.slash") {
                            app.clearSelection()
                        }
                        Spacer()
                    }
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 152), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(enabled) { account in
                        accountSelectionChip(account)
                    }
                }
            }
        }
    }

    private func selectionToolPill(_ title: String, symbol: String, action: @escaping @MainActor () -> Void) -> some View {
        Button {
            LiquidHaptics.impact(.light)
            action()
        } label: {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
        }
        .liquidGlassCapsule(variant: .clear, tint: LiquidPalette.sapphire, interactive: true)
    }

    private func accountSelectionChip(_ account: Account) -> some View {
        let isPicked = app.isSelected(account.id)
        let accent = LiquidPalette.accent(forHost: account.host)

        return Button {
            LiquidHaptics.impact(.light)
            app.toggleSelection(id: account.id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isPicked ? accent : Color.secondary.opacity(0.6))

                VStack(alignment: .leading, spacing: 2) {
                    Text(account.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Circle()
                            .fill(accent)
                            .frame(width: 6, height: 6)
                        Text(LiquidPalette.editionBadgeName(forHost: account.host))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .liquidGlassCard(
            cornerRadius: 18,
            variant: isPicked ? .regular : .clear,
            tint: isPicked ? accent : nil,
            interactive: true
        )
        .disabled(app.running)
    }

    // MARK: 并发签到控制台与实时进度玻璃环

    private var launchConsoleCard: some View {
        let targetCount = app.signTargets().count
        let canLaunch = !app.running && app.ticket != nil && app.ticket?.kind != .LOGIN && targetCount > 0
        let buttonTint = app.options.dryRun ? LiquidPalette.violet : LiquidPalette.sapphire

        return VStack(spacing: 14) {
            if let progress = app.progress, app.running {
                HStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .stroke(buttonTint.opacity(0.20), lineWidth: 6)
                        Circle()
                            .trim(from: 0, to: progress.fraction)
                            .stroke(
                                LinearGradient(
                                    colors: [LiquidPalette.cyan, buttonTint],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                style: StrokeStyle(lineWidth: 6, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                            .animation(.easeOut(duration: 0.25), value: progress.fraction)

                        Text("\(progress.completed)/\(progress.total)")
                            .font(.caption2.monospacedDigit().weight(.bold))
                    }
                    .frame(width: 56, height: 56)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.options.dryRun ? "正在生成演练轨迹…" : "正在并发执行签到…")
                            .font(.headline.weight(.semibold))
                        Text("已完成 \(progress.completed) / \(progress.total) · 命中 \(progress.succeeded) · 未通过 \(progress.failed)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(14)
                .liquidGlassCard(cornerRadius: 22, variant: .regular, tint: buttonTint)
            }

            LiquidGlassActionButton(prominence: .prominent, tint: buttonTint) {
                LiquidHaptics.impact(.medium)
                Task { await app.sign() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: app.options.dryRun ? "waveform.path.ecg" : "paperplane.fill")
                        .font(.headline)
                    Text(app.running
                         ? "并发执行中…"
                         : (app.options.dryRun ? "生成 \(targetCount) 账号演练轨迹" : "一键并发签到（\(targetCount) 账号）"))
                        .font(.headline.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .disabled(!canLaunch)

            if let report = app.report {
                Button {
                    app.activeTab = .telemetry
                } label: {
                    HStack {
                        Label(
                            "查看最近报文（成功 \(report.successCount) · 演练 \(report.dryRunCount) · 失败 \(report.failedCount)）",
                            systemImage: "waveform.path.ecg.rectangle"
                        )
                        .font(.caption.weight(.semibold))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                }
                .liquidGlassCard(cornerRadius: 16, variant: .clear, interactive: true)
            }
        }
    }

    // MARK: 辅助行为

    private func heroTint(for ticket: QrTicket) -> Color {
        if currentWarning != nil { return LiquidPalette.coral }
        switch ticket.kind {
        case .DYNAMIC_CHECKIN: return LiquidPalette.cyan
        case .LESSON_ONLY: return LiquidPalette.emerald
        case .LOGIN: return LiquidPalette.amber
        case .UNKNOWN: return LiquidPalette.slate
        }
    }

    private func pasteFromClipboard() {
        let content = UIPasteboard.general.string?.trimmed ?? ""
        guard !content.isEmpty else {
            app.notice = "剪贴板为空，请先复制二维码内容或点击「手动输入」"
            return
        }
        manualText = content
        handleScannedText(content, fromCamera: false)
    }

    @MainActor
    private func handleScannedText(_ text: String, fromCamera: Bool) {
        let cleaned = text.trimmed
        guard !cleaned.isEmpty else { return }
        let parsed = app.ingest(text: cleaned)
        // 仅当用户显式开启 autoSignOnScan、非登录码、且通过域名白名单安全检查时才自动签到
        if fromCamera && autoSignOnScan && parsed.kind != .LOGIN && app.qrSecurityWarning(for: parsed) == nil {
            Task { await app.sign() }
        }
    }
}

// MARK: - 高级参数液态玻璃浮层

struct SignOptionsSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @Binding var autoSignOnScan: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidAuroraCanvas(accent: LiquidPalette.sapphire)

                ScrollView {
                    VStack(spacing: 16) {
                        VStack(spacing: 14) {
                            LiquidSectionHeader(
                                title: "并发与节流",
                                subtitle: "账号间并发、账号内策略严格串行"
                            )

                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("并发账号数")
                                        .font(.subheadline.weight(.medium))
                                    Spacer()
                                    Text("\(app.options.concurrency)")
                                        .font(.subheadline.monospacedDigit().weight(.bold))
                                        .foregroundStyle(LiquidPalette.sapphire)
                                }
                                Stepper("", value: $app.options.concurrency, in: 1...32)
                                    .labelsHidden()
                            }

                            Divider()

                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("起步错开延迟")
                                        .font(.subheadline.weight(.medium))
                                    Spacer()
                                    Text("\(app.options.staggerMs) ms")
                                        .font(.subheadline.monospacedDigit().weight(.bold))
                                        .foregroundStyle(LiquidPalette.cyan)
                                }
                                Stepper("", value: $app.options.staggerMs, in: 0...2000, step: 20)
                                    .labelsHidden()
                            }

                            Divider()

                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("单策略最多尝试（含首次）")
                                        .font(.subheadline.weight(.medium))
                                    Spacer()
                                    Text("\(app.options.maxAttemptsPerStrategy) 次")
                                        .font(.subheadline.monospacedDigit().weight(.bold))
                                        .foregroundStyle(LiquidPalette.violet)
                                }
                                Stepper("", value: $app.options.maxAttemptsPerStrategy, in: 1...5)
                                    .labelsHidden()
                            }

                            Divider()

                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("指数退避基数")
                                        .font(.subheadline.weight(.medium))
                                    Spacer()
                                    Text("\(app.options.baseBackoffMs) ms")
                                        .font(.subheadline.monospacedDigit().weight(.bold))
                                        .foregroundStyle(LiquidPalette.emerald)
                                }
                                Stepper("", value: $app.options.baseBackoffMs, in: 200...3000, step: 200)
                                    .labelsHidden()
                            }
                        }
                        .padding(18)
                        .liquidReadableSurface(cornerRadius: 22)

                        VStack(spacing: 14) {
                            LiquidSectionHeader(
                                title: "策略与安全开关",
                                subtitle: "保护凭据与动态码时效"
                            )

                            Toggle(isOn: $app.options.dryRun) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("演练模式（Dry Run）")
                                        .font(.subheadline.weight(.medium))
                                    Text("严格零网络请求，仅生成策略轨迹供报文实验室审阅")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .tint(LiquidPalette.violet)

                            Divider()

                            Toggle(isOn: $app.options.stopWhenTicketExpired) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("遇过期立即中止后续策略")
                                        .font(.subheadline.weight(.medium))
                                    Text("动态码轮换失效时避免无效回退请求")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .tint(LiquidPalette.sapphire)

                            Divider()

                            Toggle(isOn: $autoSignOnScan) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("扫码后立即自动签到")
                                        .font(.subheadline.weight(.medium))
                                    Text("默认关闭以防止误扫外部码零点击触发；开启后仍受白名单域名拦截保护")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .tint(LiquidPalette.amber)
                        }
                        .padding(18)
                        .liquidReadableSurface(cornerRadius: 22)
                    }
                    .padding(16)
                }
            }
            .navigationTitle("高级参数")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}
