import SwiftUI

struct RootView: View {
    @EnvironmentObject var store: CloudStore

    var body: some View {
        Group {
            if !store.authReady {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("接続中…").font(.footnote).foregroundColor(.secondary)
                }
            } else if store.user == nil {
                LoginView()
            } else {
                MainTabView()
            }
        }
    }
}

struct MainTabView: View {
    @EnvironmentObject var store: CloudStore

    var body: some View {
        TabView(selection: $store.activeTab) {
            ChatTab()
                .tabItem {
                    Label(store.isExpert ? "相談一覧" : "質問者",
                          systemImage: "bubble.left.and.bubble.right.fill")
                }
                .tag(AppTab.chat)

            if store.isExpert {
                ExpertView()
                    .tabItem { Label("BA", systemImage: "person.badge.shield.checkmark.fill") }
                    .badge(store.pendingCaseCount)
                    .tag(AppTab.expert)

                NaikiView()
                    .tabItem { Label("社内ルール", systemImage: "doc.text.fill") }
                    .tag(AppTab.naiki)

                ManualView()
                    .tabItem { Label("マニュアル", systemImage: "books.vertical.fill") }
                    .tag(AppTab.manual)
            }

            SettingsView()
                .tabItem { Label("設定", systemImage: "gearshape.fill") }
                .tag(AppTab.settings)
        }
        .tint(Theme.accentDark)
    }
}
