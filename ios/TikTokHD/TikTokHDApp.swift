import SwiftUI

@main
struct TikTokHDApp: App {
    @StateObject private var browser = Browser()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(browser)
                .preferredColorScheme(.dark)
                .tint(Color(red: 0.996, green: 0.173, blue: 0.333))
        }
    }
}

enum Tab: Hashable { case patch, tiktok, accounts }

struct RootView: View {
    @EnvironmentObject var browser: Browser
    @State private var tab: Tab = .patch

    var body: some View {
        TabView(selection: $tab) {
            PatchView(openStudio: { file in
                browser.pending = file
                browser.openStudio()
                tab = .tiktok
            })
            .tabItem { Label("Patch", systemImage: "wand.and.stars") }
            .tag(Tab.patch)

            TikTokView()
                .tabItem { Label("TikTok", systemImage: "globe") }
                .tag(Tab.tiktok)
        }
    }
}
