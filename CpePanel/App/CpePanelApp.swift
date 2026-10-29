import SwiftUI

@main
struct CpePanelApp: App {
    @StateObject private var store = CpeStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(nil)   // 跟随系统
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: CpeStore
    @State private var showLogin = false

    var body: some View {
        Group {
            if store.isLoggedIn {
                MainTabView()
            } else {
                LoginView()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: store.isLoggedIn)
        .onAppear {
            Task { await store.tryAutoLogin() }
        }
        .onChange(of: store.isLoggedIn) { _, ok in
            if ok { store.startPolling() } else { store.stopPolling() }
        }
    }
}

struct MainTabView: View {
    @EnvironmentObject var store: CpeStore

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("首页", systemImage: "house.fill") }

            ControlView()
                .tabItem { Label("控制", systemImage: "slider.horizontal.3") }

            LockBandView()
                .tabItem { Label("锁频", systemImage: "lock.fill") }

            ParamView()
                .tabItem { Label("参数", systemImage: "doc.text") }

            SmsView()
                .tabItem { Label("短信", systemImage: "message.fill") }

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
        }
    }
}
