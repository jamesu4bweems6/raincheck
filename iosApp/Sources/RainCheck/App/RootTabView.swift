import SwiftUI

private enum RootTab: Hashable, Sendable {
    case checkIn
    case accounts
    case records
}

struct RootTabView: View {
    @ObservedObject var store: AppStore
    @State private var selectedTab: RootTab = .checkIn

    var body: some View {
        tabContent
            .tint(LiquidPalette.accent)
            .liquidTabBarBehavior()
            .overlay(alignment: .top) {
                if let message = store.toastMessage, !message.isEmpty {
                    LiquidToastPill(message: message)
                        .padding(.top, 12)
                        .padding(.horizontal, LiquidMetrics.pageHorizontalPadding)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .allowsHitTesting(false)
                        .zIndex(10)
                }
            }
            .animation(.spring(response: 0.34, dampingFraction: 0.86), value: store.toastMessage)
    }

    @ViewBuilder
    private var tabContent: some View {
        #if compiler(>=6.0)
        if #available(iOS 18.0, *) {
            TabView(selection: $selectedTab) {
                Tab("签到", systemImage: "qrcode.viewfinder", value: RootTab.checkIn) {
                    CheckInView(store: store)
                }

                Tab("账号", systemImage: "person.2", value: RootTab.accounts) {
                    AccountsView(store: store)
                }

                Tab("记录", systemImage: "clock.arrow.circlepath", value: RootTab.records) {
                    RecordsView(store: store)
                }
            }
        } else {
            legacyTabView
        }
        #else
        legacyTabView
        #endif
    }

    private var legacyTabView: some View {
        TabView(selection: $selectedTab) {
            CheckInView(store: store)
                .tabItem {
                    Label("签到", systemImage: "qrcode.viewfinder")
                }
                .tag(RootTab.checkIn)

            AccountsView(store: store)
                .tabItem {
                    Label("账号", systemImage: "person.2")
                }
                .tag(RootTab.accounts)

            RecordsView(store: store)
                .tabItem {
                    Label("记录", systemImage: "clock.arrow.circlepath")
                }
                .tag(RootTab.records)
        }
    }
}
