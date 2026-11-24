//
//  RainCheckApp.swift
//  RainCheck
//
//  应用入口：挂载 iOS 26 / 27 液态玻璃根容器（RainCheckRootView）。
//

import SwiftUI

@main
struct RainCheckApp: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup {
            RainCheckRootView()
                .environmentObject(app)
        }
    }
}
