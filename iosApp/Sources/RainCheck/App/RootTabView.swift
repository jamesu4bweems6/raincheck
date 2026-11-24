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
        .liquidTabBarBehavior()
        .overlay(alignment: .top) {
            if let message = store.toastMessage, !message.isEmpty {
                LiquidToastPill(message: message)
                    .padding(.top, 12)
                    .padding(.horizontal, LiquidMetrics.pageHorizontalPadding)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: store.toastMessage)
    }
}
