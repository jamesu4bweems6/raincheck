import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct PhoneLoginSheet: View {
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private enum FocusField: Hashable {
        case phone
        case smsCode
    }

    @FocusState private var focusedField: FocusField?

    @State private var selectedEdition: Edition
    @State private var phoneInput = ""
    @State private var smsCodeInput = ""
    @State private var cooldownSeconds = 0
    @State private var cooldownActive = false
    @State private var isSendingCode = false
    @State private var isSubmittingLogin = false
    @State private var showCaptcha = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var smsTask: Task<Void, Never>?
    @State private var loginTask: Task<Void, Never>?

    private var availableEditions: [Edition] {
        store.profile.editions.isEmpty ? Edition.presets : store.profile.editions
    }

    private var isUnsupportedEdition: Bool {
        let rawHost = selectedEdition.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let host: String
        if let colonIndex = rawHost.firstIndex(of: ":"), !rawHost.hasPrefix("[") {
            host = String(rawHost[..<colonIndex])
        } else {
            host = rawHost
        }
        return host == "xuetangx.com" || host.hasSuffix(".xuetangx.com")
    }

    private var isPhoneValid: Bool {
        PhoneLoginClient.isValidMainlandPhone(phoneInput)
    }

    private var isCodeValid: Bool {
        (4...8).contains(smsCodeInput.count) && smsCodeInput.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private var canRequestSmsCode: Bool {
        !isUnsupportedEdition && isPhoneValid && !isSendingCode && !isSubmittingLogin && cooldownSeconds == 0
    }

    private var canSubmitLogin: Bool {
        !isUnsupportedEdition && isPhoneValid && isCodeValid && !isSubmittingLogin
    }

    init(store: AppStore) {
        self.store = store
        let editions = store.profile.editions.isEmpty ? Edition.presets : store.profile.editions
        let defaultId = store.profile.defaultEdition
        let initialEdition = editions.first(where: { $0.id == defaultId })
            ?? editions.first(where: { $0.id == "www" })
            ?? editions.first
            ?? Edition.www
        _selectedEdition = State(initialValue: initialEdition)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidCanvas()

                ScrollView {
                    VStack(spacing: 20) {
                        editionPickerRow

                        if isUnsupportedEdition {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "info.circle")
                                    .font(.footnote.weight(.medium))
                                    .padding(.top, 1)
                                Text("学堂在线暂不支持此方式，请切换雨课堂站点")
                                    .font(.footnote)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .foregroundStyle(LiquidPalette.secondaryText)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
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

                        credentialsCard

                        Button {
                            focusedField = nil
                            loginTask?.cancel()
                            loginTask = Task {
                                await submitLogin()
                            }
                        } label: {
                            if isSubmittingLogin {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("正在登录…")
                                }
                            } else {
                                Text("登录并保存账号")
                            }
                        }
                        .liquidPrimaryButtonStyle(
                            minWidth: nil,
                            horizontalPadding: LiquidMetrics.buttonHorizontalPadding,
                            fullWidth: true
                        )
                        .disabled(!canSubmitLogin)

                        Text("仅支持中国大陆手机号，登录凭据仅保存在本机 Keychain。")
                            .font(.footnote)
                            .foregroundStyle(LiquidPalette.secondaryText)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)
                    }
                    .padding(.horizontal, LiquidMetrics.pageHorizontalPadding)
                    .padding(.top, 18)
                    .padding(.bottom, LiquidMetrics.scrollBottomPadding)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("手机号验证码登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showCaptcha) {
                CaptchaSheet(
                    edition: selectedEdition,
                    onCompleted: { token in
                        showCaptcha = false
                        smsTask?.cancel()
                        smsTask = Task {
                            await performSendSmsCode(captcha: token)
                        }
                    },
                    onCancel: {
                        showCaptcha = false
                    }
                )
            }
            .onDisappear {
                smsTask?.cancel()
                loginTask?.cancel()
            }
            .task(id: cooldownActive) {
                guard cooldownActive else { return }
                while !Task.isCancelled && cooldownSeconds > 0 {
                    do {
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                    } catch {
                        return
                    }
                    if cooldownSeconds > 0 {
                        cooldownSeconds -= 1
                    }
                }
                if !Task.isCancelled {
                    cooldownActive = false
                }
            }
        }
        .presentationDragIndicator(.visible)
    }

    private var editionPickerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("雨课堂平台")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(LiquidPalette.primaryText)

                Text(selectedEdition.host)
                    .font(.caption)
                    .foregroundStyle(LiquidPalette.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Picker(
                "雨课堂平台",
                selection: Binding(
                    get: { selectedEdition },
                    set: { newValue in
                        guard newValue != selectedEdition else { return }
                        selectedEdition = newValue
                        errorMessage = nil
                        statusMessage = nil
                    }
                )
            ) {
                ForEach(availableEditions) { edition in
                    Text(edition.label).tag(edition)
                }
            }
            .pickerStyle(.menu)
            .tint(LiquidPalette.accent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(
            LiquidPalette.elevatedSurface(colorScheme),
            in: RoundedRectangle(cornerRadius: LiquidMetrics.cornerRadiusControl + 4, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: LiquidMetrics.cornerRadiusControl + 4, style: .continuous)
                .strokeBorder(LiquidPalette.hairline(colorScheme), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private var credentialsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("手机号")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LiquidPalette.secondaryText)

                TextField(
                    "请输入 11 位手机号",
                    text: Binding(
                        get: { phoneInput },
                        set: { newValue in
                            let digits = newValue.filter { $0.isASCII && $0.isNumber }
                            phoneInput = String(digits.prefix(11))
                            errorMessage = nil
                        }
                    )
                )
                .keyboardType(.numberPad)
                .textContentType(.telephoneNumber)
                .font(.system(.body, design: .monospaced))
                .focused($focusedField, equals: .phone)
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .background(
                    LiquidPalette.subtleSurface(colorScheme),
                    in: RoundedRectangle(cornerRadius: LiquidMetrics.cornerRadiusControl, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: LiquidMetrics.cornerRadiusControl, style: .continuous)
                        .strokeBorder(
                            focusedField == .phone
                                ? LiquidPalette.accent.opacity(0.65)
                                : LiquidPalette.hairline(colorScheme),
                            lineWidth: focusedField == .phone ? 1.25 : 1
                        )
                        .allowsHitTesting(false)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("短信验证码")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LiquidPalette.secondaryText)

                HStack(spacing: 10) {
                    TextField(
                        "6 位验证码",
                        text: Binding(
                            get: { smsCodeInput },
                            set: { newValue in
                                let digits = newValue.filter { $0.isASCII && $0.isNumber }
                                smsCodeInput = String(digits.prefix(8))
                                errorMessage = nil
                            }
                        )
                    )
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.system(.body, design: .monospaced))
                    .focused($focusedField, equals: .smsCode)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .background(
                        LiquidPalette.subtleSurface(colorScheme),
                        in: RoundedRectangle(cornerRadius: LiquidMetrics.cornerRadiusControl, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: LiquidMetrics.cornerRadiusControl, style: .continuous)
                            .strokeBorder(
                                focusedField == .smsCode
                                    ? LiquidPalette.accent.opacity(0.65)
                                    : LiquidPalette.hairline(colorScheme),
                                lineWidth: focusedField == .smsCode ? 1.25 : 1
                            )
                            .allowsHitTesting(false)
                    }

                    Button {
                        handleRequestSmsCode()
                    } label: {
                        if isSendingCode {
                            ProgressView()
                                .controlSize(.small)
                        } else if cooldownSeconds > 0 {
                            Text("\(cooldownSeconds)s 后重发")
                                .font(.subheadline.monospacedDigit().weight(.medium))
                        } else {
                            Text("获取验证码")
                                .font(.subheadline.weight(.medium))
                        }
                    }
                    .liquidSecondaryButtonStyle(
                        minWidth: 124,
                        horizontalPadding: LiquidMetrics.buttonCompactHorizontalPadding
                    )
                    .layoutPriority(1)
                    .disabled(!canRequestSmsCode)
                }
            }

            if let statusMessage, !statusMessage.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(LiquidPalette.accent)
                        .padding(.top, 1)
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(LiquidPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    LiquidPalette.accent.opacity(colorScheme == .dark ? 0.14 : 0.08),
                    in: RoundedRectangle(cornerRadius: LiquidMetrics.cornerRadiusControl, style: .continuous)
                )
            }

            if let errorMessage, !errorMessage.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.footnote.weight(.medium))
                        .padding(.top, 1)
                    Text(errorMessage)
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(LiquidPalette.primaryText)
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
        }
        .padding(LiquidMetrics.cardPadding)
        .liquidGlassCard()
    }

    private func handleRequestSmsCode() {
        focusedField = nil
        errorMessage = nil
        guard canRequestSmsCode else { return }

        if PhoneLoginClient.requiresWebCaptcha(for: selectedEdition) {
            showCaptcha = true
        } else {
            smsTask?.cancel()
            smsTask = Task {
                await performSendSmsCode(captcha: CaptchaToken())
            }
        }
    }

    private func performSendSmsCode(captcha: CaptchaToken) async {
        guard !isSendingCode else { return }
        let targetEdition = selectedEdition
        let targetPhone = phoneInput

        isSendingCode = true
        errorMessage = nil
        defer { isSendingCode = false }

        do {
            try await store.phoneLoginClient.sendSmsCode(
                edition: targetEdition,
                phone: targetPhone,
                captcha: captcha
            )
            guard !Task.isCancelled else { return }
            cooldownSeconds = 60
            cooldownActive = true
            statusMessage = "验证码已发送至 \(Self.maskPhone(targetPhone))"
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func submitLogin() async {
        guard canSubmitLogin else { return }
        let targetEdition = selectedEdition
        let targetPhone = phoneInput
        let targetCode = smsCodeInput

        isSubmittingLogin = true
        errorMessage = nil
        defer { isSubmittingLogin = false }

        do {
            let account = try await store.phoneLoginClient.loginWithSmsCode(
                edition: targetEdition,
                phone: targetPhone,
                code: targetCode
            )
            guard !Task.isCancelled else { return }
            try store.addOrUpdateAccount(account)
            dismiss()
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    private static func maskPhone(_ raw: String) -> String {
        let digits = raw.filter { $0.isASCII && $0.isNumber }
        guard digits.count == 11 else { return digits }
        return "\(digits.prefix(3))****\(digits.suffix(4))"
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

    private var availableEditions: [Edition] {
        store.profile.editions.isEmpty ? Edition.presets : store.profile.editions
    }

    init(store: AppStore, editing: Account? = nil) {
        self.store = store
        self.editing = editing

        let editions = store.profile.editions.isEmpty ? Edition.presets : store.profile.editions
        if let editing {
            if let matched = editions.first(where: {
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
            let initialId = editions.first(where: { $0.id == defaultId })?.id
                ?? editions.first?.id
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
        CredentialSanitizer.cleanCookieValue(sessionIdInput, key: "sessionid", allowBareValue: true)
    }

    private var cleanedCsrfToken: String? {
        if let direct = CredentialSanitizer.cleanCookieValue(csrfTokenInput, key: "csrftoken", allowBareValue: true) {
            return direct
        }
        return CredentialSanitizer.cleanCookieValue(sessionIdInput, key: "csrftoken", allowBareValue: false)
    }

    private var resolvedHostAndScheme: (host: String, scheme: String) {
        if selectedEditionId == Self.customEditionId {
            let parsed = CredentialSanitizer.cleanHost(customHost)
            let fallbackScheme = editing?.scheme ?? "https"
            return (parsed.host, parsed.scheme ?? fallbackScheme)
        }
        if let preset = availableEditions.first(where: { $0.id == selectedEditionId }) {
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
                            ForEach(availableEditions) { edition in
                                Text(edition.label).tag(edition.id)
                            }
                            Text("自定义域名").tag(Self.customEditionId)
                        }

                        if selectedEditionId == Self.customEditionId {
                            TextField("例如：pro.yuketang.cn", text: $customHost)
                                .font(.system(.body, design: .monospaced))
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
                    .listRowSeparatorTint(LiquidPalette.hairline(colorScheme))

                    Section {
                        HStack(alignment: .center, spacing: 10) {
                            TextField("Bearer Token（支持自动清理前缀）", text: $bearerInput, axis: .vertical)
                                .lineLimit(2...4)
                                .font(.system(.callout, design: .monospaced))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()

                            #if canImport(UIKit)
                            Button {
                                if let pasted = UIPasteboard.general.string {
                                    errorMessage = nil
                                    bearerInput = CredentialSanitizer.cleanBearer(pasted) ?? pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "doc.on.clipboard")
                                    Text("粘贴")
                                        .lineLimit(1)
                                }
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(LiquidPalette.accent)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .frame(minWidth: 74, minHeight: 34)
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
                            #endif
                        }

                        HStack(alignment: .center, spacing: 10) {
                            TextField("sessionid（支持直接粘贴整段 Cookie）", text: $sessionIdInput)
                                .font(.system(.callout, design: .monospaced))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()

                            #if canImport(UIKit)
                            Button {
                                if let pasted = UIPasteboard.general.string {
                                    errorMessage = nil
                                    if let sid = CredentialSanitizer.cleanCookieValue(pasted, key: "sessionid", allowBareValue: true) {
                                        sessionIdInput = sid
                                    } else {
                                        sessionIdInput = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                                    }
                                    if csrfTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                       let csrf = CredentialSanitizer.cleanCookieValue(pasted, key: "csrftoken", allowBareValue: false) {
                                        csrfTokenInput = csrf
                                    }
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "doc.on.clipboard")
                                    Text("粘贴")
                                        .lineLimit(1)
                                }
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(LiquidPalette.accent)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .frame(minWidth: 74, minHeight: 34)
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
                            #endif
                        }

                        TextField("csrftoken（可选）", text: $csrfTokenInput)
                            .font(.system(.callout, design: .monospaced))
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
                    .listRowSeparatorTint(LiquidPalette.hairline(colorScheme))

                    Section {
                        Button {
                            saveAccount()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                Text(editing == nil ? "保存并导入账号" : "保存修改")
                            }
                        }
                        .liquidPrimaryButtonStyle(
                            minWidth: nil,
                            horizontalPadding: LiquidMetrics.buttonHorizontalPadding,
                            fullWidth: true
                        )
                        .disabled(validationError != nil)
                        .listRowBackground(Color.clear)
                        .listRowInsets(
                            EdgeInsets(
                                top: 10,
                                leading: 0,
                                bottom: LiquidMetrics.scrollBottomPadding,
                                trailing: 0
                            )
                        )
                        .listRowSeparator(.hidden)
                    }
                    .listSectionSeparator(.hidden)
                }
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.interactively)
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
