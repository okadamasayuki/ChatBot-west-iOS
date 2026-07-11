import SwiftUI
import UIKit

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
        // 同じタブをもう一度タップしたら、開いている画面(相談チャットなど)を閉じて一覧に戻す
        TabView(selection: Binding(
            get: { store.activeTab },
            set: { newTab in
                if newTab == store.activeTab {
                    if newTab == .chat { store.backToRooms() }
                    if newTab == .baChat { store.backToBaTalks() }
                }
                store.activeTab = newTab
            }
        )) {
            ChatTab()
                .tabItem {
                    Label(store.isExpert ? "相談一覧" : "質問者",
                          systemImage: "bubble.left.and.bubble.right.fill")
                }
                // 未回答かつ対応者が決まっていない案件の数(財務のみ)
                .badge(store.isExpert ? store.unassignedCaseCount : 0)
                .tag(AppTab.chat)

            if store.isExpert {
                BaChatView()
                    .tabItem { Label("BAチャット", systemImage: "person.2.fill") }
                    .badge(store.totalTalkUnread) // 全トークの未読合計
                    .tag(AppTab.baChat)

                NotificationsView()
                    .tabItem { Label("通知", systemImage: "bell.fill") }
                    .badge(store.unreadNotificationCount)
                    .tag(AppTab.notifications)
            }

            if store.isExpert {
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

/// 戻るボタンを隠しても左端スワイプで戻れるようにする
extension UINavigationController: UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}
