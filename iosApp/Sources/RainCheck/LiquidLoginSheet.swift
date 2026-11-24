//
//  LiquidLoginSheet.swift
//  RainCheck
//
//  液态玻璃微信扫码登录页：
//   - 使用 `.task(id: flowGeneration)` 受管任务生命周期：关闭弹窗自动取消轮询，
//     点击刷新递增 `flowGeneration` 安全取消旧任务，彻底杜绝后台泄漏与双轮询竞态；
//   - 复用 `LiquidQRCodeView` 缓存二维码位图，绝不在 `body` 重绘时重建 `CIContext`；
//   - 完整支持 `PENDING` / `SCANNED` / 4 位验证码 `NEED_CODE` 玻璃输入框 / `AUTHORIZED` / `EXPIRED` / `ERROR`。
//

import SwiftUI

struct LiquidLoginSheet: View {
    let edition: Edition

    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @Namespace private var loginNamespace

    @State private var flowGeneration: Int = 0
    @State private var loginState: LoginState = .PENDING
    @State private var qrContent: String = ""
    @State private var loginToken: String = ""
    @State private var statusMessage: String = "正在申请登录二维码…"
    @State private var codeInput: String = ""
    @State private var submittingCode: Bool = false
    @State private var remainingSeconds: Int = 180
    @State private var authorizedAccount: Account?
    @State private var loadingQR: Bool = true

    init(edition: Edition) {
        self.edition = edition
    }

    private var accent: Color {
        LiquidPalette.accent(forHost: edition.host, editionId: edition.id)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidAuroraCanvas(accent: accent)

                ScrollView {
                    VStack(spacing: 18) {
                        statusPillHeader
                        mainStageCard

                        if loginState == .NEED_CODE {
                            verificationCodeCard
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }

                        actionFooter
                    }
                    .padding(20)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("扫码登录 · \(edition.label)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        LiquidHaptics.impact(.light)
                        flowGeneration += 1
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(submittingCode || loginState == .AUTHORIZED)
                    .accessibilityLabel("刷新登录二维码")
                }
            }
            // 受管异步任务：视图销毁自动取消，刷新时递增 flowGeneration 自动取消上一轮轮询
            .task(id: flowGeneration) {
                await runManagedLoginFlow()
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.84), value: loginState)
    }

    // MARK: 状态胶囊

    private var statusPillHeader: some View {
        HStack(spacing: 8) {
            LiquidStatusPill(
                text: loginState.displayName,
                symbol: stateSymbol,
                tint: stateTint
            )
            .liquidGlassMorphID("login-state", in: loginNamespace)

            if loginState == .PENDING || loginState == .SCANNED {
                LiquidStatusPill(
                    text: "\(remainingSeconds)s",
                    symbol: "timer",
                    tint: remainingSeconds <= 25 ? LiquidPalette.rose : LiquidPalette.cyan
                )
            }
        }
    }

    // MARK: 主视觉舞台

    @ViewBuilder
    private var mainStageCard: some View {
        VStack(spacing: 16) {
            if let account = authorizedAccount, loginState == .AUTHORIZED {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(LiquidPalette.emerald)
                    Text("已加入账号舱")
                        .font(.title3.weight(.bold))
                    Text(account.label)
                        .font(.headline)
                    Text("\(account.scheme)://\(account.host)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 24)
            } else if !qrContent.isEmpty {
                LiquidQRCodeView(content: qrContent, size: 224)

                if loginState == .SCANNED {
                    HStack(spacing: 8) {
                        Image(systemName: "iphone.radiowaves.left.and.right")
                            .foregroundStyle(LiquidPalette.emerald)
                        Text("已检测到微信扫码，请在手机微信上点击确认登录")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(LiquidPalette.emerald)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .liquidGlassCapsule(variant: .clear, tint: LiquidPalette.emerald)
                }
            } else if loadingQR {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("正在连接 \(edition.host)…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(height: 220)
            } else {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 50))
                    .foregroundStyle(LiquidPalette.amber)
                    .padding(.vertical, 24)
            }

            Text(statusMessage)
                .font(.footnote)
                .foregroundStyle(loginState == .ERROR || loginState == .EXPIRED ? LiquidPalette.coral : .secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .liquidGlassCard(cornerRadius: 28, variant: .regular, tint: stateTint)
        .liquidGlassMorphID("login-stage", in: loginNamespace)
    }

    // MARK: 4 位验证码玻璃输入框

    private var verificationCodeCard: some View {
        let digits = Array(codeInput.filter { $0.isNumber }.prefix(4))

        return VStack(alignment: .leading, spacing: 12) {
            LiquidSectionHeader(
                title: "输入 4 位数字验证码",
                subtitle: "微信确认后若提示安全校验，请输入屏幕显示的 4 位数字",
                tint: LiquidPalette.amber
            )

            // 4 个发光数字玻璃格
            HStack(spacing: 10) {
                ForEach(0..<4, id: \.self) { index in
                    let char = index < digits.count ? String(digits[index]) : ""
                    Text(char.isEmpty ? "•" : char)
                        .font(.title2.monospacedDigit().weight(.bold))
                        .foregroundStyle(char.isEmpty ? Color.secondary.opacity(0.4) : Color.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .liquidGlassCard(
                            cornerRadius: 16,
                            variant: char.isEmpty ? .clear : .regular,
                            tint: char.isEmpty ? nil : LiquidPalette.amber
                        )
                }
            }

            HStack(spacing: 10) {
                TextField("请输入 4 位数字", text: $codeInput)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.system(.body, design: .monospaced))
                    .padding(12)
                    .liquidReadableSurface(cornerRadius: 14)
                    .onValueChange(of: codeInput) { newValue in
                        let filtered = String(newValue.filter { $0.isNumber }.prefix(4))
                        if filtered != newValue {
                            codeInput = filtered
                        }
                    }

                LiquidGlassActionButton(prominence: .prominent, tint: LiquidPalette.amber) {
                    Task { await submitVerificationCode() }
                } label: {
                    Text(submittingCode ? "提交中…" : "确认")
                        .font(.subheadline.weight(.semibold))
                }
                .disabled(submittingCode || digits.count != 4)
            }
        }
        .padding(16)
        .liquidGlassCard(cornerRadius: 24, variant: .regular, tint: LiquidPalette.amber)
    }

    // MARK: 底部操作区

    @ViewBuilder
    private var actionFooter: some View {
        LiquidGlassGroup(spacing: 10) {
            if loginState == .AUTHORIZED {
                LiquidGlassActionButton(prominence: .prominent, tint: LiquidPalette.emerald) {
                    dismiss()
                } label: {
                    Label("完成并返回账号舱", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
            } else if loginState == .EXPIRED || loginState == .ERROR {
                LiquidGlassActionButton(prominence: .prominent, tint: accent) {
                    LiquidHaptics.impact(.medium)
                    flowGeneration += 1
                } label: {
                    Label("重新生成登录二维码", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: 受管轮询状态机

    @MainActor
    private func runManagedLoginFlow() async {
        loadingQR = true
        loginState = .PENDING
        qrContent = ""
        loginToken = ""
        codeInput = ""
        authorizedAccount = nil
        remainingSeconds = 180
        statusMessage = "正在申请 \(edition.label) 登录二维码…"

        let started = await app.loginStart(edition: edition)
        guard !Task.isCancelled else { return }
        loadingQR = false

        guard started.state == .PENDING,
              let token = started.loginToken?.trimmedNonEmpty,
              let qr = started.qrContent?.trimmedNonEmpty else {
            loginState = started.state == .EXPIRED ? .EXPIRED : .ERROR
            statusMessage = started.message
            return
        }

        loginToken = token
        qrContent = qr
        statusMessage = started.message

        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if Task.isCancelled { return }
            remainingSeconds = max(0, Int(deadline.timeIntervalSinceNow.rounded(.up)))
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                return
            }
            if Task.isCancelled { return }

            let polled = await app.loginPoll(edition: edition, loginToken: loginToken)
            guard !Task.isCancelled else { return }

            switch polled.state {
            case .AUTHORIZED:
                if let account = polled.account, app.adoptLogin(polled) {
                    authorizedAccount = account
                    loginState = .AUTHORIZED
                    statusMessage = "登录成功，凭据已安全存入 Keychain"
                    LiquidHaptics.notify(.success)
                } else {
                    loginState = .ERROR
                    statusMessage = polled.message
                    LiquidHaptics.notify(.error)
                }
                return
            case .NEED_CODE:
                loginToken = polled.loginToken ?? loginToken
                loginState = .NEED_CODE
                statusMessage = polled.message
                LiquidHaptics.notify(.warning)
                return
            case .SCANNED:
                loginState = .SCANNED
                statusMessage = polled.message
            case .PENDING:
                loginState = .PENDING
                statusMessage = polled.message
            case .EXPIRED:
                loginState = .EXPIRED
                statusMessage = polled.message
                LiquidHaptics.notify(.warning)
                return
            case .ERROR:
                loginState = .ERROR
                statusMessage = polled.message
                LiquidHaptics.notify(.error)
                return
            }
        }

        loginState = .EXPIRED
        remainingSeconds = 0
        statusMessage = "登录二维码已超时（180 秒），请刷新重新生成。"
    }

    @MainActor
    private func submitVerificationCode() async {
        let digits = codeInput.filter { $0.isNumber }
        guard digits.count == 4, !submittingCode else { return }
        submittingCode = true
        statusMessage = "正在提交 4 位验证码…"
        defer { submittingCode = false }

        let result = await app.loginSubmitCode(edition: edition, loginToken: loginToken, code: digits)
        switch result.state {
        case .AUTHORIZED:
            if let account = result.account, app.adoptLogin(result) {
                authorizedAccount = account
                loginState = .AUTHORIZED
                statusMessage = "验证通过，账号已安全存入 Keychain"
                LiquidHaptics.notify(.success)
            } else {
                loginState = .ERROR
                statusMessage = result.message
                LiquidHaptics.notify(.error)
            }
        case .NEED_CODE:
            loginToken = result.loginToken ?? loginToken
            loginState = .NEED_CODE
            codeInput = ""
            statusMessage = result.message
            LiquidHaptics.notify(.warning)
        case .EXPIRED:
            loginState = .EXPIRED
            statusMessage = result.message
            LiquidHaptics.notify(.warning)
        case .ERROR:
            loginState = .ERROR
            statusMessage = result.message
            LiquidHaptics.notify(.error)
        case .PENDING, .SCANNED:
            loginState = result.state
            statusMessage = result.message
        }
    }

    private var stateTint: Color {
        switch loginState {
        case .PENDING: return accent
        case .SCANNED: return LiquidPalette.emerald
        case .NEED_CODE: return LiquidPalette.amber
        case .AUTHORIZED: return LiquidPalette.emerald
        case .EXPIRED: return LiquidPalette.rose
        case .ERROR: return LiquidPalette.coral
        }
    }

    private var stateSymbol: String {
        switch loginState {
        case .PENDING: return "qrcode"
        case .SCANNED: return "checkmark.circle"
        case .NEED_CODE: return "lock.rectangle.on.rectangle"
        case .AUTHORIZED: return "checkmark.seal.fill"
        case .EXPIRED: return "clock.badge.xmark"
        case .ERROR: return "exclamationmark.triangle.fill"
        }
    }
}
