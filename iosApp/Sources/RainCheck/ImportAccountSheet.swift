//
//  ImportAccountSheet.swift
//  RainCheck
//
//  液态玻璃凭据导入页：
//   - 自动剥离 `Bearer ` / `Authorization:` 前缀并解析 Cookie（`sessionid`/`csrftoken`）；
//   - 自动清洗自定义 host 的 `https://`/`http://` 前缀与尾部 `/`；
//   - 严禁全空凭据或裸 `Bearer ` 入库；
//   - 校验失败时在 sheet 内持续展示液态玻璃错误横幅（提供「返回修改」或「忽略校验强制保存」），
//     绝不瞬闪关闭，也绝不重复 `upsert`。
//

import SwiftUI

private let importCustomEditionTag = "__custom__"

struct ImportAccountSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var label: String = ""
    @State private var editionId: String = ""
    @State private var customHost: String = ""
    @State private var customScheme: String = "https"
    @State private var credentialText: String = ""
    @State private var verifyBeforeSave: Bool = true
    @State private var busy: Bool = false
    @State private var errorBanner: String?
    @State private var pendingUnverifiedAccount: Account?

    init() {}

    private var parsedPreview: AccountVaultStore.ParsedCredentials {
        AccountVaultStore.parseCredentials(credentialText)
    }

    private var resolvedEdition: Edition? {
        if editionId == importCustomEditionTag {
            guard let clean = AccountVaultStore.normalizeCustomHost(customHost, fallbackScheme: customScheme) else {
                return nil
            }
            return Edition(id: clean.host, label: clean.host, host: clean.host, scheme: clean.scheme)
        }
        return app.profileStore.edition(id: editionId) ?? app.profileStore.defaultEdition
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidAuroraCanvas(accent: LiquidPalette.sapphire)

                ScrollView {
                    VStack(spacing: 16) {
                        if let errorBanner {
                            validationErrorCard(errorBanner)
                        }

                        identityCard
                        credentialCard
                        verifyToggleCard
                    }
                    .padding(16)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("导入账号凭据")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "校验中…" : "保存") {
                        Task { await attemptSave(forceWithoutVerify: false) }
                    }
                    .disabled(busy || !parsedPreview.hasAny || resolvedEdition == nil)
                }
            }
            .onAppear {
                if editionId.isEmpty {
                    editionId = app.profileStore.defaultEdition.id
                }
            }
            .onValueChange(of: credentialText) { _ in
                pendingUnverifiedAccount = nil
                errorBanner = nil
            }
            .onValueChange(of: customHost) { _ in
                pendingUnverifiedAccount = nil
                errorBanner = nil
            }
        }
    }

    // MARK: 玻璃错误横幅（绝不瞬闪关闭）

    private func validationErrorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.headline)
                    .foregroundStyle(LiquidPalette.coral)
                VStack(alignment: .leading, spacing: 4) {
                    Text("校验未通过")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(LiquidPalette.coral)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.primary)
                }
                Spacer()
            }

            if pendingUnverifiedAccount != nil {
                HStack(spacing: 10) {
                    LiquidGlassActionButton(prominence: .glass, tint: LiquidPalette.amber) {
                        Task { await attemptSave(forceWithoutVerify: true) }
                    } label: {
                        Label("忽略校验强制保存", systemImage: "tray.and.arrow.down.fill")
                            .font(.caption.weight(.semibold))
                    }

                    Button("继续修改") {
                        pendingUnverifiedAccount = nil
                        errorBanner = nil
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .liquidGlassCard(cornerRadius: 20, variant: .regular, tint: LiquidPalette.coral)
    }

    // MARK: 站点与名称卡片

    private var identityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            LiquidSectionHeader(title: "账号与校区", subtitle: "支持 7 套内置站点或自定义高校私有站点")

            TextField("账号昵称（留空自动命名或校验回填）", text: $label)
                .padding(12)
                .liquidReadableSurface(cornerRadius: 14)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(app.profileStore.editions) { edition in
                        let selected = editionId == edition.id
                        let tint = LiquidPalette.accent(forHost: edition.host, editionId: edition.id)
                        Button {
                            LiquidHaptics.impact(.light)
                            editionId = edition.id
                        } label: {
                            Text(edition.label)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(selected ? .white : .primary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                        }
                        .liquidGlassCapsule(
                            variant: selected ? .regular : .clear,
                            tint: selected ? tint : nil,
                            interactive: true
                        )
                    }

                    let isCustom = editionId == importCustomEditionTag
                    Button {
                        LiquidHaptics.impact(.light)
                        editionId = importCustomEditionTag
                    } label: {
                        Text("自定义站点")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isCustom ? .white : .primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                    .liquidGlassCapsule(
                        variant: isCustom ? .regular : .clear,
                        tint: isCustom ? LiquidPalette.slate : nil,
                        interactive: true
                    )
                }
            }

            if editionId == importCustomEditionTag {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("输入域名或地址（自动清洗 https:// 与尾部 /）", text: $customHost)
                        .font(.system(.footnote, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .padding(12)
                        .liquidReadableSurface(cornerRadius: 14)

                    Picker("协议", selection: $customScheme) {
                        Text("HTTPS").tag("https")
                        Text("HTTP（仅限本地/内网）").tag("http")
                    }
                    .pickerStyle(.segmented)

                    if let resolved = resolvedEdition {
                        Text("规范化地址：\(resolved.baseUrl)")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(LiquidPalette.emerald)
                    } else if !customHost.trimmed.isEmpty {
                        Text("域名格式无效，请检查是否包含非法空格。")
                            .font(.caption2)
                            .foregroundStyle(LiquidPalette.coral)
                    }
                }
            } else if let resolved = resolvedEdition {
                Text("目标站点：\(resolved.baseUrl)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .liquidReadableSurface(cornerRadius: 22)
    }

    // MARK: 凭据输入卡片

    private var credentialCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            LiquidSectionHeader(
                title: "登录凭据",
                subtitle: "自动识别并清洗 Bearer Token 或 Cookie（sessionid / csrftoken）"
            )

            TextEditor(text: $credentialText)
                .font(.system(.footnote, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 130)
                .padding(10)
                .liquidReadableSurface(cornerRadius: 14)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)

            HStack(spacing: 8) {
                LiquidStatusPill(
                    text: parsedPreview.bearer != nil ? "已识别 Bearer" : "无 Bearer",
                    symbol: parsedPreview.bearer != nil ? "checkmark.circle.fill" : "circle",
                    tint: parsedPreview.bearer != nil ? LiquidPalette.sapphire : LiquidPalette.slate
                )
                LiquidStatusPill(
                    text: parsedPreview.sessionId != nil ? "已识别 Session" : "无 Session",
                    symbol: parsedPreview.sessionId != nil ? "checkmark.circle.fill" : "circle",
                    tint: parsedPreview.sessionId != nil ? LiquidPalette.cyan : LiquidPalette.slate
                )
                if parsedPreview.csrfToken != nil {
                    LiquidStatusPill(
                        text: "已识别 CSRF",
                        symbol: "checkmark.circle.fill",
                        tint: LiquidPalette.emerald
                    )
                }
            }
        }
        .padding(16)
        .liquidReadableSurface(cornerRadius: 22)
    }

    private var verifyToggleCard: some View {
        Toggle(isOn: $verifyBeforeSave) {
            VStack(alignment: .leading, spacing: 2) {
                Text("入库前通过 basic-info 校验会话")
                    .font(.subheadline.weight(.medium))
                Text("校验成功会自动回填昵称与 UID；失败时保留当前页提示，不会误关弹窗。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .tint(LiquidPalette.emerald)
        .padding(16)
        .liquidReadableSurface(cornerRadius: 22)
    }

    // MARK: 保存与单次入库逻辑

    @MainActor
    private func attemptSave(forceWithoutVerify: Bool) async {
        guard !busy else { return }

        if forceWithoutVerify, let pending = pendingUnverifiedAccount {
            var copy = pending
            copy.note = "未通过入库校验，建议实测或重新登录"
            app.upsert(copy)
            LiquidHaptics.notify(.warning)
            dismiss()
            return
        }

        let parsed = AccountVaultStore.parseCredentials(credentialText)
        guard parsed.hasAny else {
            errorBanner = "未检测到有效凭据（请粘贴非空 Bearer Token 或 sessionid Cookie，纯前缀无效）。"
            LiquidHaptics.notify(.error)
            return
        }
        guard let edition = resolvedEdition else {
            errorBanner = "请填写合法的自定义域名（无需携带 https:// 或尾部斜杠）。"
            LiquidHaptics.notify(.error)
            return
        }

        busy = true
        errorBanner = nil
        pendingUnverifiedAccount = nil
        defer { busy = false }

        let draft = Account(
            id: Ids.randomId(),
            label: label.trimmedNonEmpty ?? "账号 \(Ids.shortId())",
            host: edition.host,
            scheme: edition.scheme,
            bearer: parsed.bearer,
            sessionId: parsed.sessionId,
            csrfToken: parsed.csrfToken,
            enabled: true,
            createdAt: TimeUtil.nowMillis()
        )

        if verifyBeforeSave {
            if let verified = await app.verify(account: draft) {
                var finalAccount = verified
                if let customName = label.trimmedNonEmpty {
                    finalAccount.label = customName
                }
                finalAccount.note = ""
                // 单次 upsert，绝不重复写入
                app.upsert(finalAccount)
                LiquidHaptics.notify(.success)
                dismiss()
                return
            } else {
                pendingUnverifiedAccount = draft
                errorBanner = "向 \(edition.baseUrl) 请求 basic-info 校验未通过。请确认站点选择正确且凭据未过期，或选择强制保存。"
                LiquidHaptics.notify(.warning)
                return
            }
        }

        app.upsert(draft)
        LiquidHaptics.notify(.success)
        dismiss()
    }
}
