//
//  AccountVaultView.swift
//  RainCheck
//
//  液态玻璃「账号舱」：
//   - 顶部液态玻璃健康度仪表条（有效 / 待续期 / 已停用）与一键巡检；
//   - 按校区着色的玻璃账号卡片（雨课堂 / 荷塘 Pro / 长江 / 黄河 / 学堂在线 / 本地演练），
//     直观呈现 Bearer + Cookie + CSRF 双载体鉴权状态；
//   - 便捷触发「粘贴导入凭据」（ImportAccountSheet）与「微信扫码登录」（LiquidLoginSheet）；
//   - 透明展示协议配置与 Keychain 安全存储状态。
//

import SwiftUI

struct AccountVaultView: View {
    @EnvironmentObject private var app: AppState

    @State private var showingImportSheet = false
    @State private var loginEdition: Edition?
    @State private var verifyingAccountId: String?

    init() {}

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidAuroraCanvas(accent: LiquidPalette.violet)

                ScrollView {
                    VStack(spacing: 18) {
                        if let error = app.profileStore.loadError {
                            fallbackWarningCard(error)
                        }

                        healthDashboardBar
                        quickActionRow
                        accountCardsSection
                        vaultSecurityInfoCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("账号舱")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            showingImportSheet = true
                        } label: {
                            Label("粘贴导入凭据", systemImage: "key.fill")
                        }

                        Button {
                            Task { await app.verifyAccounts() }
                        } label: {
                            Label("校验全部账号", systemImage: "checkmark.shield")
                        }
                        .disabled(app.verifying || app.accounts.isEmpty)

                        Divider()

                        ForEach(app.profileStore.editions) { edition in
                            Button {
                                loginEdition = edition
                            } label: {
                                Label("扫码登录 · \(edition.label)", systemImage: "qrcode")
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.headline.weight(.semibold))
                    }
                    .accessibilityLabel("添加或扫码登录账号")
                }
            }
            .sheet(isPresented: $showingImportSheet) {
                ImportAccountSheet()
                    .environmentObject(app)
            }
            .sheet(item: $loginEdition) { edition in
                LiquidLoginSheet(edition: edition)
                    .environmentObject(app)
            }
        }
    }

    // MARK: 顶部健康度仪表条

    private var healthDashboardBar: some View {
        LiquidGlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                healthMetricPod(
                    title: "有效",
                    count: app.healthyAccountCount,
                    symbol: "checkmark.shield.fill",
                    tint: LiquidPalette.emerald
                )
                healthMetricPod(
                    title: "待续期",
                    count: app.renewalNeededCount,
                    symbol: "exclamationmark.triangle.fill",
                    tint: LiquidPalette.amber
                )
                healthMetricPod(
                    title: "已停用",
                    count: app.disabledAccountCount,
                    symbol: "pause.circle.fill",
                    tint: LiquidPalette.slate
                )
            }
        }
    }

    private func healthMetricPod(title: String, count: Int, symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: symbol)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                Spacer()
                Text("\(count)")
                    .font(.title2.monospacedDigit().weight(.bold))
                    .foregroundStyle(.primary)
            }
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassCard(cornerRadius: 20, variant: .regular, tint: tint)
    }

    // MARK: 快捷入口栏

    private var quickActionRow: some View {
        LiquidGlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                LiquidGlassActionButton(prominence: .prominent, tint: LiquidPalette.sapphire) {
                    showingImportSheet = true
                } label: {
                    Label("导入凭据", systemImage: "square.and.pencil")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }

                Menu {
                    ForEach(app.profileStore.editions) { edition in
                        Button {
                            loginEdition = edition
                        } label: {
                            Label(edition.label, systemImage: "qrcode")
                        }
                    }
                } label: {
                    Label("扫码登录", systemImage: "qrcode")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .liquidGlassCapsule(variant: .regular, tint: LiquidPalette.violet, interactive: true)
                }

                Button {
                    LiquidHaptics.impact(.light)
                    Task { await app.verifyAccounts() }
                } label: {
                    Group {
                        if app.verifying {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    .frame(width: 44, height: 42)
                }
                .liquidGlass(.regular, tint: LiquidPalette.emerald, interactive: true, in: Circle())
                .disabled(app.verifying || app.accounts.isEmpty)
                .accessibilityLabel("巡检全部账号")
            }
        }
    }

    // MARK: 账号卡片列表

    private var accountCardsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LiquidSectionHeader(
                title: "账号池",
                subtitle: "敏感凭据存于本机 Keychain，元信息不随 iCloud 备份",
                trailingBadge: "共 \(app.accounts.count) 个",
                tint: LiquidPalette.violet
            )

            if app.accounts.isEmpty {
                emptyVaultCard
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(app.accounts) { account in
                        AccountGlassCard(
                            account: account,
                            isVerifying: verifyingAccountId == account.id,
                            onToggleEnabled: { enabled in
                                app.setEnabled(id: account.id, enabled: enabled)
                            },
                            onVerifySingle: {
                                Task { await verifySingle(account) }
                            },
                            onDelete: {
                                LiquidHaptics.impact(.medium)
                                app.delete(id: account.id)
                            }
                        )
                    }
                }
            }
        }
    }

    private var emptyVaultCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(LiquidPalette.violet)
            Text("账号舱为空")
                .font(.headline.weight(.semibold))
            Text("点击「导入凭据」粘贴 Bearer Token / Cookie，或点击「扫码登录」用微信授权添加账号。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .liquidReadableSurface(cornerRadius: 22)
    }

    // MARK: 协议与安全仓库信息

    private var vaultSecurityInfoCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            LiquidSectionHeader(
                title: "协议与安全仓库",
                trailingBadge: "v\(app.profileStore.profile.version)",
                tint: LiquidPalette.sapphire
            )

            infoRow("协议包", "\(app.profileStore.summary)（\(app.profileStore.source)）")
            infoRow("策略顺序", app.profileStore.strategyChainText)
            infoRow("凭据存储", app.vaultStore.storageSummary)
        }
        .padding(16)
        .liquidReadableSurface(cornerRadius: 22)
    }

    private func fallbackWarningCard(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(LiquidPalette.amber)
            Text(text)
                .font(.caption)
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(12)
        .liquidGlassCard(cornerRadius: 16, variant: .regular, tint: LiquidPalette.amber)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
        }
    }

    @MainActor
    private func verifySingle(_ account: Account) async {
        guard verifyingAccountId == nil else { return }
        verifyingAccountId = account.id
        defer { verifyingAccountId = nil }

        guard let passed = await app.verifyAccount(id: account.id) else {
            return
        }
        LiquidHaptics.notify(passed ? .success : .warning)
    }
}

// MARK: - 按校区着色的单账号液态玻璃卡片

private struct AccountGlassCard: View {
    @EnvironmentObject private var app: AppState

    let account: Account
    let isVerifying: Bool
    let onToggleEnabled: @MainActor (Bool) -> Void
    let onVerifySingle: @MainActor () -> Void
    let onDelete: @MainActor () -> Void

    private var campusTint: Color {
        LiquidPalette.accent(forHost: account.host)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        LiquidStatusPill(
                            text: LiquidPalette.editionBadgeName(forHost: account.host),
                            tint: campusTint
                        )
                        Text(account.label)
                            .font(.headline.weight(.semibold))
                            .lineLimit(1)
                        if let uid = account.userId?.trimmedNonEmpty {
                            Text("#\(uid)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("\(account.scheme)://\(account.host)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 6)

                Toggle("", isOn: Binding(
                    get: { account.enabled },
                    set: { newValue in
                        MainActor.assumeIsolated {
                            onToggleEnabled(newValue)
                        }
                    }
                ))
                .labelsHidden()
                .tint(campusTint)
                .disabled(isVerifying || app.running)
            }

            // 双载体凭据状态条
            HStack(spacing: 6) {
                carrierChip(name: "Bearer", active: account.hasBearer, tint: LiquidPalette.sapphire)
                carrierChip(name: "Cookie", active: account.hasSessionCookie, tint: LiquidPalette.cyan)
                carrierChip(name: "CSRF", active: account.hasCsrf, tint: LiquidPalette.emerald)

                Spacer(minLength: 4)

                Text(account.maskedCredential())
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                if let lastOk = account.lastOkAt, lastOk > 0 {
                    Label("活跃 \(TimeUtil.formatRelative(millis: lastOk))", systemImage: "clock")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Label("尚未校验", systemImage: "questionmark.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    onVerifySingle()
                } label: {
                    if isVerifying {
                        ProgressView().controlSize(.mini)
                    } else {
                        Label("校验", systemImage: "checkmark.shield")
                            .font(.caption2.weight(.semibold))
                    }
                }
                .disabled(isVerifying || app.running)

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("删除", systemImage: "trash")
                        .font(.caption2.weight(.semibold))
                }
                .disabled(isVerifying || app.running)
            }

            if !account.note.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                    Text(account.note)
                        .font(.caption2)
                }
                .foregroundStyle(LiquidPalette.amber)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LiquidPalette.amber.opacity(0.14))
                }
            }
        }
        .padding(16)
        .opacity(account.enabled ? 1.0 : 0.68)
        .liquidGlassCard(cornerRadius: 22, variant: .regular, tint: account.enabled ? campusTint : LiquidPalette.slate)
    }

    private func carrierChip(name: String, active: Bool, tint: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(active ? tint : Color.secondary.opacity(0.35))
                .frame(width: 6, height: 6)
            Text(name)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(active ? .primary : .secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .liquidReadableSurface(cornerRadius: 10)
    }
}
