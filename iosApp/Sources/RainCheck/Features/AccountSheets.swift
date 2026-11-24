import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct QrLoginSheet: View {
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var selectedEdition: Edition
    @State private var sessionKey = UUID()
    @State private var stage: QrLoginStage = .loading
    @State private var activeSession: QrLoginSession?
    @State private var pinCode = ""
    @State private var isSubmittingCode = false

    init(store: AppStore) {
        self.store = store
        let defaultId = store.profile.defaultEdition
        let initialEdition = Edition.presets.first(where: { $0.id == defaultId })
            ?? Edition.presets.first
            ?? Edition(id: "www", label: "雨课堂", host: "www.yuketang.cn", scheme: "https")
        _selectedEdition = State(initialValue: initialEdition)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidCanvas()

                ScrollView {
                    VStack(spacing: 22) {
                        editionPickerRow

                        stageContentCard

                        statusFooter
                    }
                    .padding(.horizontal, LiquidMetrics.pageHorizontalPadding)
                    .padding(.vertical, 20)
                }
            }
            .navigationTitle("扫码登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
            .task(id: sessionKey) {
                await runLoginSession()
            }
        }
        .presentationDragIndicator(.visible)
    }

    private var editionPickerRow: some View {
        HStack {
            Text("雨课堂平台")
                .font(.subheadline)
                .foregroundStyle(LiquidPalette.secondaryText)

            Spacer()

            Picker(
                "雨课堂平台",
                selection: Binding(
                    get: { selectedEdition },
                    set: { newValue in
                        guard newValue != selectedEdition else { return }
                        selectedEdition = newValue
                        restartSession()
                    }
                )
            ) {
                ForEach(Edition.presets) { edition in
                    Text(edition.label).tag(edition)
                }
            }
            .pickerStyle(.menu)
            .tint(LiquidPalette.accent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            LiquidPalette.elevatedSurface(colorScheme),
            in: RoundedRectangle(cornerRadius: LiquidMetrics.cornerRadiusControl, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LiquidMetrics.cornerRadiusControl, style: .continuous)
                .strokeBorder(LiquidPalette.hairline(colorScheme), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var stageContentCard: some View {
        switch stage {
        case .idle, .loading:
            VStack(spacing: 14) {
                ProgressView()
                    .tint(LiquidPalette.accent)
                Text("正在获取登录二维码…")
                    .font(.subheadline)
                    .foregroundStyle(LiquidPalette.secondaryText)
            }
            .frame(width: 248, height: 248)
            .liquidGlassCard()

        case .waitingScan(let qrContent, _), .scanned(let qrContent, _):
            QrCodePlateView(content: qrContent, size: 216)

        case .needsCode(_, let message):
            VStack(spacing: 16) {
                Image(systemName: "lock.shield")
                    .font(.title2)
                    .foregroundStyle(LiquidPalette.primaryText)

                Text(message ?? "请输入微信显示的 4 位验证码")
                    .font(.subheadline)
                    .foregroundStyle(LiquidPalette.secondaryText)
                    .multilineTextAlignment(.center)

                TextField("0000", text: Binding(
                    get: { pinCode },
                    set: { newValue in
                        let digits = newValue.filter { $0.isASCII && $0.isNumber }
                        pinCode = String(digits.prefix(4))
                    }
                ))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .font(.system(.title, design: .monospaced).weight(.semibold))
                .padding(.vertical, 12)
                .frame(maxWidth: 180)
                .background(
                    LiquidPalette.subtleSurface(colorScheme),
                    in: RoundedRectangle(cornerRadius: LiquidMetrics.cornerRadiusControl, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: LiquidMetrics.cornerRadiusControl, style: .continuous)
                        .strokeBorder(LiquidPalette.hairline(colorScheme), lineWidth: 1)
                )

                Button {
                    Task {
                        await submitVerificationCode()
                    }
                } label: {
                    if isSubmittingCode {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("确认登录")
                            .frame(maxWidth: .infinity)
                    }
                }
                .liquidPrimaryButtonStyle()
                .disabled(pinCode.count != 4 || isSubmittingCode)
            }
            .padding(LiquidMetrics.cardPadding)
            .liquidGlassCard()

        case .verifyingCode:
            VStack(spacing: 14) {
                ProgressView()
                    .tint(LiquidPalette.accent)
                Text("正在校验安全码…")
                    .font(.subheadline)
                    .foregroundStyle(LiquidPalette.secondaryText)
            }
            .frame(width: 248, height: 180)
            .liquidGlassCard()

        case .succeeded:
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle")
                    .font(.largeTitle)
                    .foregroundStyle(LiquidPalette.accent)
                Text("登录成功")
                    .font(.headline)
                    .foregroundStyle(LiquidPalette.primaryText)
            }
            .frame(width: 248, height: 180)
            .liquidGlassCard()

        case .expired(let reason):
            VStack(spacing: 16) {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.title2)
                    .foregroundStyle(LiquidPalette.secondaryText)
                Text(reason)
                    .font(.subheadline)
                    .foregroundStyle(LiquidPalette.secondaryText)
                    .multilineTextAlignment(.center)
                Button("重新获取二维码") {
                    restartSession()
                }
                .liquidSecondaryButtonStyle()
            }
            .padding(LiquidMetrics.cardPadding)
            .frame(maxWidth: .infinity)
            .liquidGlassCard()

        case .failed(let reason):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.circle")
                    .font(.title2)
                    .foregroundStyle(LiquidPalette.secondaryText)
                Text(reason)
                    .font(.subheadline)
                    .foregroundStyle(LiquidPalette.secondaryText)
                    .multilineTextAlignment(.center)
                Button("重试") {
                    restartSession()
                }
                .liquidSecondaryButtonStyle()
            }
            .padding(LiquidMetrics.cardPadding)
            .frame(maxWidth: .infinity)
            .liquidGlassCard()
        }
    }

    @ViewBuilder
    private var statusFooter: some View {
        switch stage {
        case .waitingScan:
            Text("请使用微信扫描上方二维码登录 \(selectedEdition.label)")
                .font(.footnote)
                .foregroundStyle(LiquidPalette.secondaryText)
                .multilineTextAlignment(.center)
        case .scanned:
            Text("已扫码，请在微信中点击确认登录")
                .font(.footnote.weight(.medium))
                .foregroundStyle(LiquidPalette.primaryText)
                .multilineTextAlignment(.center)
        default:
            EmptyView()
        }
    }

    private func restartSession() {
        pinCode = ""
        activeSession = nil
        stage = .loading
        sessionKey = UUID()
    }

    private func runLoginSession() async {
        stage = .loading
        activeSession = nil
        pinCode = ""

        do {
            let session = try await store.loginClient.startSession(edition: selectedEdition)
            if Task.isCancelled { return }
            activeSession = session
            stage = .waitingScan(qrContent: session.qrContent, loginToken: session.loginToken)

            while !Task.isCancelled {
                let waitOutcome = await store.loginClient.waitForScan(session: session)
                if Task.isCancelled { return }
                if handlePollOutcome(waitOutcome, session: session) {
                    return
                }

                let pollOutcome = await store.loginClient.pollLogin(session: session)
                if Task.isCancelled { return }
                if handlePollOutcome(pollOutcome, session: session) {
                    return
                }

                try await Task.sleep(nanoseconds: 1_500_000_000)
            }
        } catch is CancellationError {
            return
        } catch let loginError as QrLoginError {
            guard !Task.isCancelled else { return }
            switch loginError {
            case .expired(let message):
                stage = .expired(message)
            case .failed(let message):
                stage = .failed(message)
            }
        } catch {
            if !Task.isCancelled {
                stage = .failed(error.localizedDescription)
            }
        }
    }

    private func handlePollOutcome(_ outcome: QrLoginPollOutcome, session: QrLoginSession) -> Bool {
        switch outcome {
        case .pending:
            if case .scanned = stage {
                return false
            }
            stage = .waitingScan(qrContent: session.qrContent, loginToken: session.loginToken)
            return false

        case .scanned:
            stage = .scanned(qrContent: session.qrContent, loginToken: session.loginToken)
            return false

        case .needsCode(let message):
            stage = .needsCode(loginToken: session.loginToken, message: message)
            return true

        case .authenticated(let account):
            finishAuthenticated(account)
            return true

        case .expired(let message):
            stage = .expired(message)
            return true

        case .failed(let message):
            stage = .failed(message)
            return true
        }
    }

    private func submitVerificationCode() async {
        guard let session = activeSession, pinCode.count == 4 else { return }
        isSubmittingCode = true
        stage = .verifyingCode
        let outcome = await store.loginClient.submitCode(session: session, code: pinCode)
        guard activeSession?.loginToken == session.loginToken else {
            isSubmittingCode = false
            return
        }
        isSubmittingCode = false

        switch outcome {
        case .authenticated(let account):
            finishAuthenticated(account)
        case .needsCode(let message):
            pinCode = ""
            stage = .needsCode(loginToken: session.loginToken, message: message ?? "验证码无效，请重试")
        case .expired(let message):
            stage = .expired(message)
        case .failed(let message):
            stage = .failed(message)
        case .pending, .scanned:
            stage = .needsCode(loginToken: session.loginToken, message: "请重新输入验证码")
        }
    }

    private func finishAuthenticated(_ account: Account) {
        do {
            try store.addOrUpdateAccount(account)
            stage = .succeeded(account)
            dismiss()
        } catch {
            stage = .failed("保存账号失败：\(error.localizedDescription)")
        }
    }
}

struct ManualImportSheet: View {
    @ObservedObject var store: AppStore
    let editing: Account?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private static let customEditionId = "__custom__"

    @State private var selectedEditionId: String
    @State private var customHost: String
    @State private var label: String
    @State private var note: String
    @State private var bearerInput: String
    @State private var sessionIdInput: String
    @State private var csrfTokenInput: String
    @State private var errorMessage: String?

    init(store: AppStore, editing: Account? = nil) {
        self.store = store
        self.editing = editing

        if let editing {
            if let matched = Edition.presets.first(where: {
                $0.host.caseInsensitiveCompare(editing.host) == .orderedSame &&
                    $0.scheme.caseInsensitiveCompare(editing.scheme) == .orderedSame
            }) {
                _selectedEditionId = State(initialValue: matched.id)
                _customHost = State(initialValue: "")
            } else {
                _selectedEditionId = State(initialValue: Self.customEditionId)
                _customHost = State(initialValue: editing.host)
            }
            _label = State(initialValue: editing.label)
            _note = State(initialValue: editing.note)
            _bearerInput = State(initialValue: editing.bearer ?? "")
            _sessionIdInput = State(initialValue: editing.sessionId ?? "")
            _csrfTokenInput = State(initialValue: editing.csrfToken ?? "")
        } else {
            let defaultId = store.profile.defaultEdition
            let initialId = Edition.presets.first(where: { $0.id == defaultId })?.id
                ?? Edition.presets.first?.id
                ?? "www"
            _selectedEditionId = State(initialValue: initialId)
            _customHost = State(initialValue: "")
            _label = State(initialValue: "")
            _note = State(initialValue: "")
            _bearerInput = State(initialValue: "")
            _sessionIdInput = State(initialValue: "")
            _csrfTokenInput = State(initialValue: "")
        }
    }

    private var cleanedBearer: String? {
        CredentialSanitizer.cleanBearer(bearerInput)
    }

    private var cleanedSessionId: String? {
        CredentialSanitizer.cleanCookieValue(sessionIdInput, key: "sessionid")
    }

    private var cleanedCsrfToken: String? {
        if let direct = CredentialSanitizer.cleanCookieValue(csrfTokenInput, key: "csrftoken") {
            return direct
        }
        return CredentialSanitizer.cleanCookieValue(sessionIdInput, key: "csrftoken")
    }

    private var resolvedHostAndScheme: (host: String, scheme: String) {
        if selectedEditionId == Self.customEditionId {
            let parsed = CredentialSanitizer.cleanHost(customHost)
            let fallbackScheme = editing?.scheme ?? "https"
            return (parsed.host, parsed.scheme ?? fallbackScheme)
        }
        if let preset = Edition.presets.first(where: { $0.id == selectedEditionId }) {
            return (preset.host, preset.scheme)
        }
        return ("www.yuketang.cn", "https")
    }

    private var validationError: String? {
        if resolvedHostAndScheme.host.isEmpty {
            return "请填写有效的平台域名。"
        }
        if cleanedBearer == nil && cleanedSessionId == nil {
            return "请至少填写 Bearer Token 或 SessionID 后再保存。"
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidCanvas()

                Form {
                    Section {
                        Picker("雨课堂平台", selection: $selectedEditionId) {
                            ForEach(Edition.presets) { edition in
                                Text(edition.label).tag(edition.id)
                            }
                            Text("自定义域名").tag(Self.customEditionId)
                        }

                        if selectedEditionId == Self.customEditionId {
                            TextField("例如：pro.yuketang.cn", text: $customHost)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                        }

                        TextField("账号备注（选填）", text: $label)
                        TextField("补充说明（选填）", text: $note)
                    } header: {
                        Text("基本信息")
                    }
                    .listRowBackground(LiquidPalette.elevatedSurface(colorScheme))

                    Section {
                        HStack(alignment: .top, spacing: 8) {
                            TextField("Bearer Token（支持自动清理前缀）", text: $bearerInput, axis: .vertical)
                                .lineLimit(2...4)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()

                            #if canImport(UIKit)
                            Button("粘贴") {
                                if let pasted = UIPasteboard.general.string {
                                    errorMessage = nil
                                    bearerInput = CredentialSanitizer.cleanBearer(pasted) ?? pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                                }
                            }
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(LiquidPalette.accent)
                            .buttonStyle(.plain)
                            #endif
                        }

                        HStack(spacing: 8) {
                            TextField("sessionid（支持直接粘贴整段 Cookie）", text: $sessionIdInput)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()

                            #if canImport(UIKit)
                            Button("粘贴") {
                                if let pasted = UIPasteboard.general.string {
                                    errorMessage = nil
                                    if let sid = CredentialSanitizer.cleanCookieValue(pasted, key: "sessionid") {
                                        sessionIdInput = sid
                                    } else {
                                        sessionIdInput = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                                    }
                                    if csrfTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                       let csrf = CredentialSanitizer.cleanCookieValue(pasted, key: "csrftoken") {
                                        csrfTokenInput = csrf
                                    }
                                }
                            }
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(LiquidPalette.accent)
                            .buttonStyle(.plain)
                            #endif
                        }

                        TextField("csrftoken（可选）", text: $csrfTokenInput)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } header: {
                        Text("登录凭据")
                    } footer: {
                        VStack(alignment: .leading, spacing: 6) {
                            if let message = errorMessage ?? validationError {
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: "info.circle")
                                    Text(message)
                                }
                                .font(.footnote)
                                .foregroundStyle(LiquidPalette.primaryText)
                            } else {
                                Text("凭据仅保存在本机 Keychain，不会写入导出日志。")
                                    .font(.footnote)
                                    .foregroundStyle(LiquidPalette.secondaryText)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .listRowBackground(LiquidPalette.elevatedSurface(colorScheme))
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle(editing == nil ? "手动导入" : "编辑账号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        saveAccount()
                    }
                    .disabled(validationError != nil)
                }
            }
        }
        .presentationDragIndicator(.visible)
    }

    private func saveAccount() {
        errorMessage = nil
        if let validationError {
            errorMessage = validationError
            return
        }

        let target = resolvedHostAndScheme
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedLabel = trimmedLabel.isEmpty
            ? LiquidPalette.editionDisplayName(forHost: target.host)
            : trimmedLabel

        let account = Account(
            id: editing?.id ?? UUID().uuidString,
            label: resolvedLabel,
            host: target.host,
            scheme: target.scheme,
            bearer: cleanedBearer,
            sessionId: cleanedSessionId,
            csrfToken: cleanedCsrfToken,
            enabled: editing?.enabled ?? true,
            createdAt: editing?.createdAt ?? RainCheckTime.nowMillis(),
            lastOkAt: editing?.lastOkAt,
            userId: editing?.userId,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        do {
            try store.addOrUpdateAccount(account)
            dismiss()
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)"
        }
    }
}
