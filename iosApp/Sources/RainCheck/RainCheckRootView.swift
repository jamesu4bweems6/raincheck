//
//  RainCheckRootView.swift
//  RainCheck
//
//  原生液态玻璃三栏根视图（签到台 / 账号舱 / 报文实验室）：
//   - iOS 26+ 自动激活原生液态玻璃浮动 Tab 栏与 `.tabBarMinimizeBehavior(.onScrollDown)`；
//   - 顶部浮动液态玻璃提示条替代侵入式系统弹窗；
//   - 统一提供 `SignState` 语义配色扩展。
//

import SwiftUI

extension SignState {
    var tintColor: Color {
        switch self {
        case .SUCCESS: return LiquidPalette.emerald
        case .ALREADY: return LiquidPalette.cyan
        case .DRY_RUN: return LiquidPalette.violet
        case .AUTH_REQUIRED: return LiquidPalette.amber
        case .TICKET_EXPIRED: return LiquidPalette.rose
        case .NO_CONTEXT: return LiquidPalette.slate
        case .FAILED: return LiquidPalette.coral
        case .ERROR: return Color.red
        }
    }
}

struct RainCheckRootView: View {
    @EnvironmentObject private var app: AppState
    @Namespace private var noticeNamespace

    init() {}

    var body: some View {
        ZStack(alignment: .top) {
            TabView(selection: $app.activeTab) {
                SignStudioView()
                    .tabItem {
                        Label(AppTab.studio.title, systemImage: AppTab.studio.symbolName)
                    }
                    .tag(AppTab.studio)

                AccountVaultView()
                    .tabItem {
                        Label(AppTab.vault.title, systemImage: AppTab.vault.symbolName)
                    }
                    .tag(AppTab.vault)

                TelemetryLabView()
                    .tabItem {
                        Label(AppTab.telemetry.title, systemImage: AppTab.telemetry.symbolName)
                    }
                    .tag(AppTab.telemetry)
            }
            .tint(LiquidPalette.sapphire)
            .liquidTabBarBehavior()

            if let notice = app.notice {
                noticeBanner(notice)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(50)
            }
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.84), value: app.notice)
    }

    private func noticeBanner(_ text: String) -> some View {
        LiquidGlassGroup(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "info.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LiquidPalette.amber)

                Text(text)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    app.dismissNotice()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .padding(6)
                }
                .accessibilityLabel("关闭提示")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .liquidGlassCard(cornerRadius: 18, variant: .regular, tint: LiquidPalette.amber)
            .liquidGlassMorphID("global-notice", in: noticeNamespace)
        }
    }
}
