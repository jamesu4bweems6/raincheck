import SwiftUI

private enum AccountSheetRoute: Identifiable {
    case phoneLogin
    case manualCreate
    case manualEdit(Account)

    var id: String {
        switch self {
        case .phoneLogin: return "phone-login"
        case .manualCreate: return "manual-create"
        case .manualEdit(let account): return "manual-edit-\(account.id)"
        }
    }
}

struct AccountsView: View {
    @ObservedObject var store: AppStore
    @Environment(\.colorScheme) private var colorScheme

    @State private var activeSheet: AccountSheetRoute?

    private var enabledCount: Int {
        store.accounts.filter(\.enabled).count
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidCanvas()

                if store.accounts.isEmpty {
                    emptyView
                } else {
                    accountListView
                }
            }
            .navigationTitle("账号")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            activeSheet = .phoneLogin
                        } label: {
                            Label("手机号验证码登录", systemImage: "iphone")
                        }

                        Button {
                            activeSheet = .manualCreate
                        } label: {
                            Label("手动导入", systemImage: "key.horizontal")
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.body.weight(.medium))
                            .accessibilityLabel("添加账号")
                    }
                }
            }
            .sheet(item: $activeSheet) { route in
                switch route {
                case .phoneLogin:
                    PhoneLoginSheet(store: store)
                case .manualCreate:
                    ManualImportSheet(store: store, editing: nil)
                case .manualEdit(let account):
                    ManualImportSheet(store: store, editing: account)
                }
            }
        }
    }

    private var emptyView: some View {
        VStack(spacing: 24) {
            LiquidEmptyState(
                symbol: "person.crop.circle.badge.plus",
                title: "还没有账号",
                message: "点击右上角 + 或下方按钮，通过手机号验证码登录或手动导入凭据，集中管理多个雨课堂账号。"
            )

            LiquidGlassGroup(spacing: 12) {
                VStack(spacing: 12) {
                    Button {
                        activeSheet = .phoneLogin
                    } label: {
                        Label("手机号验证码登录", systemImage: "iphone")
                    }
                    .liquidPrimaryButtonStyle(
                        minWidth: nil,
                        horizontalPadding: LiquidMetrics.buttonHorizontalPadding,
                        fullWidth: true
                    )

                    Button {
                        activeSheet = .manualCreate
                    } label: {
                        Label("手动导入", systemImage: "key.horizontal")
                    }
                    .liquidSecondaryButtonStyle(
                        minWidth: nil,
                        horizontalPadding: LiquidMetrics.buttonHorizontalPadding,
                        fullWidth: true
                    )
                }
            }
            .frame(maxWidth: 340)
        }
        .padding(.horizontal, LiquidMetrics.pageHorizontalPadding)
        .padding(.bottom, LiquidMetrics.scrollBottomPadding)
    }

    private var accountListView: some View {
        List {
            Section {
                ForEach(store.accounts) { account in
                    accountRow(account)
                        .listRowBackground(LiquidPalette.elevatedSurface(colorScheme))
                        .listRowSeparatorTint(LiquidPalette.hairline(colorScheme))
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                store.deleteAccount(id: account.id)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }

                            Button {
                                activeSheet = .manualEdit(account)
                            } label: {
                                Label("编辑", systemImage: "pencil")
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                Task {
                                    await store.verifyAccount(id: account.id)
                                }
                            } label: {
                                Label("验证凭据", systemImage: "checkmark.shield")
                            }
                            .tint(LiquidPalette.accent)
                        }
                        .contextMenu {
                            Button {
                                Task {
                                    await store.verifyAccount(id: account.id)
                                }
                            } label: {
                                Label("验证凭据", systemImage: "checkmark.shield")
                            }

                            Button {
                                activeSheet = .manualEdit(account)
                            } label: {
                                Label("编辑", systemImage: "pencil")
                            }

                            Divider()

                            Button(role: .destructive) {
                                store.deleteAccount(id: account.id)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                }
            } header: {
                Text("共 \(store.accounts.count) 个 · 已启用 \(enabledCount) 个")
                    .font(.footnote.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(LiquidPalette.secondaryText)
                    .textCase(nil)
            }

            Section {
                LiquidGlassGroup(spacing: 12) {
                    HStack(spacing: 12) {
                        Button {
                            activeSheet = .phoneLogin
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "iphone")
                                Text("验证码登录")
                            }
                        }
                        .liquidPrimaryButtonStyle(
                            minWidth: nil,
                            horizontalPadding: LiquidMetrics.buttonCompactHorizontalPadding,
                            fullWidth: true
                        )

                        Button {
                            activeSheet = .manualCreate
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "key.horizontal")
                                Text("手动导入")
                            }
                        }
                        .liquidSecondaryButtonStyle(
                            minWidth: nil,
                            horizontalPadding: LiquidMetrics.buttonCompactHorizontalPadding,
                            fullWidth: true
                        )
                    }
                }
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
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func accountRow(_ account: Account) -> some View {
        let isVerifying = store.verifyingAccountIds.contains(account.id)
        let isReady = account.enabled && account.hasCredential && account.lastOkAt != nil

        return HStack(spacing: 12) {
            Image(systemName: account.enabled ? "person.crop.circle.fill" : "person.crop.circle")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(isReady ? LiquidPalette.accent : LiquidPalette.secondaryText)
                .frame(width: 38, height: 38)
                .background(
                    isReady
                        ? LiquidPalette.accent.opacity(colorScheme == .dark ? 0.16 : 0.10)
                        : LiquidPalette.subtleSurface(colorScheme),
                    in: Circle()
                )
                .overlay {
                    Circle()
                        .strokeBorder(
                            isReady
                                ? LiquidPalette.accent.opacity(colorScheme == .dark ? 0.28 : 0.20)
                                : LiquidPalette.hairline(colorScheme),
                            lineWidth: 0.75
                        )
                        .allowsHitTesting(false)
                }

            VStack(alignment: .leading, spacing: 5) {
                Text(account.label)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(account.enabled ? LiquidPalette.primaryText : LiquidPalette.secondaryText)
                    .lineLimit(1)

                Text("\(LiquidPalette.editionDisplayName(forHost: account.host)) · \(account.host)")
                    .font(.caption)
                    .foregroundStyle(LiquidPalette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    accountStatusBadge(for: account, isVerifying: isVerifying, isReady: isReady)

                    Text(account.authKindLabel)
                        .font(.caption2)
                        .foregroundStyle(LiquidPalette.tertiaryText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Toggle(
                "",
                isOn: Binding(
                    get: { account.enabled },
                    set: { _ in store.toggleAccountEnabled(id: account.id) }
                )
            )
            .labelsHidden()
            .tint(LiquidPalette.accent)
            .accessibilityLabel("启用 \(account.label)")
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func accountStatusBadge(for account: Account, isVerifying: Bool, isReady: Bool) -> some View {
        HStack(spacing: 4) {
            if isVerifying {
                ProgressView()
                    .controlSize(.mini)
                Text("验证中")
            } else {
                Text(statusCaption(for: account))
            }
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(isReady && !isVerifying ? LiquidPalette.accent : LiquidPalette.secondaryText)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            isReady && !isVerifying
                ? LiquidPalette.accent.opacity(colorScheme == .dark ? 0.16 : 0.10)
                : LiquidPalette.subtleSurface(colorScheme),
            in: Capsule()
        )
        .overlay {
            Capsule()
                .strokeBorder(
                    isReady && !isVerifying
                        ? LiquidPalette.accent.opacity(colorScheme == .dark ? 0.28 : 0.20)
                        : LiquidPalette.hairline(colorScheme),
                    lineWidth: 0.5
                )
                .allowsHitTesting(false)
        }
    }

    private func statusCaption(for account: Account) -> String {
        if !account.enabled {
            return "已停用"
        }
        if !account.hasCredential {
            return "待验证"
        }
        if account.lastOkAt != nil {
            return "已就绪"
        }
        return "待验证"
    }
}
