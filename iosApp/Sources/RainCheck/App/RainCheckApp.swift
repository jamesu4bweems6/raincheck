import SwiftUI

@main
struct RainCheckApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootTabView(store: store)
                .tint(LiquidPalette.accent)
        }
    }
}
